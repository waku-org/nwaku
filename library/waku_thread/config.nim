

import
  std/[json,strformat,options]
import
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  stew/shims/net,
  ../../waku/waku_enr/capabilities,
  ../../waku/common/utils/nat,
  ../../waku/node/waku_node,
  ../../waku/node/config,
  ../events/json_base_event

proc parsePrivateKey(jsonNode: JsonNode,
                     privateKey: var PrivateKey,
                     errorResp: var string): bool =

  if not jsonNode.contains("key"):
    privateKey = PrivateKey.random(Secp256k1, newRng()[]).tryGet()
    return true

  if jsonNode["key"].kind != JsonNodeKind.JString:
    errorResp = "The node key should be a string."
    return false

  let key = jsonNode["key"].getStr()

  try:
    let skPrivKey = SkPrivateKey.init(crypto.fromHex(key)).tryGet()
    privateKey = crypto.PrivateKey(scheme: Secp256k1, skkey: skPrivKey)
  except CatchableError:
    let msg = "Invalid node key: " & getCurrentExceptionMsg()
    errorResp = msg
    return false

  return true

proc parseListenAddr(jsonNode: JsonNode,
                     listenAddr: var IpAddress,
                     errorResp: var string): bool =

  if not jsonNode.contains("host"):
    errorResp = "host attribute is required"
    return false

  if jsonNode["host"].kind != JsonNodeKind.JString:
    errorResp = "The node host should be a string."
    return false

  let host = jsonNode["host"].getStr()

  try:
    listenAddr = parseIpAddress(host)
  except CatchableError:
    let msg = "Invalid host IP address: " & getCurrentExceptionMsg()
    errorResp = msg
    return false

  return true

proc parsePort(jsonNode: JsonNode,
               port: var int,
               errorResp: var string): bool =

  if not jsonNode.contains("port"):
    errorResp = "port attribute is required"
    return false

  if jsonNode["port"].kind != JsonNodeKind.JInt:
    errorResp = "The node port should be an integer."
    return false

  port = jsonNode["port"].getInt()

  return true

proc parseRelay(jsonNode: JsonNode,
                relay: var bool,
                errorResp: var string): bool =

  if not jsonNode.contains("relay"):
    errorResp = "relay attribute is required"
    return false

  if jsonNode["relay"].kind != JsonNodeKind.JBool:
    errorResp = "The relay config param should be a boolean"
    return false

  relay = jsonNode["relay"].getBool()

  return true

proc parseStore(jsonNode: JsonNode,
                store: var bool,
                storeNode: var string,
                storeRetentionPolicy: var string,
                storeDbUrl: var string,
                storeVacuum: var bool,
                storeDbMigration: var bool,
                storeMaxNumDbConnections: var int,
                errorResp: var string): bool =

  if not jsonNode.contains("store"):
    ## the store parameter is not required. By default is is disabled
    store = false
    return true

  if jsonNode["store"].kind != JsonNodeKind.JBool:
    errorResp = "The store config param should be a boolean"
    return false

  store = jsonNode["store"].getBool()

  if jsonNode.contains("storeNode"):
    if jsonNode["storeNode"].kind != JsonNodeKind.JString:
      errorResp = "The storeNode config param should be a string"
      return false

    storeNode = jsonNode["storeNode"].getStr()

  if jsonNode.contains("storeRetentionPolicy"):
    if jsonNode["storeRetentionPolicy"].kind != JsonNodeKind.JString:
      errorResp = "The storeRetentionPolicy config param should be a string"
      return false

    storeRetentionPolicy = jsonNode["storeRetentionPolicy"].getStr()

  if jsonNode.contains("storeDbUrl"):
    if jsonNode["storeDbUrl"].kind != JsonNodeKind.JString:
      errorResp = "The storeDbUrl config param should be a string"
      return false

    storeDbUrl = jsonNode["storeDbUrl"].getStr()

  if jsonNode.contains("storeVacuum"):
    if jsonNode["storeVacuum"].kind != JsonNodeKind.JBool:
      errorResp = "The storeVacuum config param should be a bool"
      return false

    storeVacuum = jsonNode["storeVacuum"].getBool()

  if jsonNode.contains("storeDbMigration"):
    if jsonNode["storeDbMigration"].kind != JsonNodeKind.JBool:
      errorResp = "The storeDbMigration config param should be a bool"
      return false

    storeDbMigration = jsonNode["storeDbMigration"].getBool()

  if jsonNode.contains("storeMaxNumDbConnections"):
    if jsonNode["storeMaxNumDbConnections"].kind != JsonNodeKind.JInt:
      errorResp = "The storeMaxNumDbConnections config param should be an int"
      return false

    storeMaxNumDbConnections = jsonNode["storeMaxNumDbConnections"].getInt()

  return true

proc parseTopics(jsonNode: JsonNode, topics: var seq[string]) =
  if jsonNode.contains("topics"):
    for topic in jsonNode["topics"].items:
      topics.add(topic.getStr())
  else:
    topics = @["/waku/2/default-waku/proto"]

proc parseConfig*(configNodeJson: string,
                  privateKey: var PrivateKey,
                  netConfig: var NetConfig,
                  relay: var bool,
                  topics: var seq[string],
                  store: var bool,
                  storeNode: var string,
                  storeRetentionPolicy: var string,
                  storeDbUrl: var string,
                  storeVacuum: var bool,
                  storeDbMigration: var bool,
                  storeMaxNumDbConnections: var int,
                  errorResp: var string): bool {.raises: [].} =

  if configNodeJson.len == 0:
    errorResp = "The configNodeJson is empty"
    return false

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(configNodeJson)
  except Exception, IOError, JsonParsingError:
    errorResp = "Exception: " & getCurrentExceptionMsg()
    return false

  # key
  try:
    if not parsePrivateKey(jsonNode, privateKey, errorResp):
      return false
  except Exception, KeyError:
    errorResp = "Exception calling parsePrivateKey: " & getCurrentExceptionMsg()
    return false

  # listenAddr
  var listenAddr: IpAddress
  try:
    listenAddr = parseIpAddress("127.0.0.1")
    if not parseListenAddr(jsonNode, listenAddr, errorResp):
      return false
  except Exception, ValueError:
    errorResp = "Exception calling parseIpAddress: " & getCurrentExceptionMsg()
    return false

  # port
  var port = 0
  try:
    if not parsePort(jsonNode, port, errorResp):
      return false
  except Exception, ValueError:
    errorResp = "Exception calling parsePort: " & getCurrentExceptionMsg()
    return false

  let natRes = setupNat("any", clientId,
                        Port(uint16(port)),
                        Port(uint16(port)))
  if natRes.isErr():
    errorResp = "failed to setup NAT: " & $natRes.error
    return false

  let (extIp, extTcpPort, _) = natRes.get()

  let extPort = if extIp.isSome() and extTcpPort.isNone():
                  some(Port(uint16(port)))
                else:
                  extTcpPort

  # relay
  try:
    if not parseRelay(jsonNode, relay, errorResp):
      return false
  except Exception, KeyError:
    errorResp = "Exception calling parseRelay: " & getCurrentExceptionMsg()
    return false

  # topics
  try:
    parseTopics(jsonNode, topics)
  except Exception, KeyError:
    errorResp = "Exception calling parseTopics: " & getCurrentExceptionMsg()
    return false

  # store
  try:
    if not parseStore(jsonNode, store, storeNode, storeRetentionPolicy, storeDbUrl,
                      storeVacuum, storeDbMigration, storeMaxNumDbConnections, errorResp):
      return false
  except Exception, KeyError:
    errorResp = "Exception calling parseStore: " & getCurrentExceptionMsg()
    return false

  let wakuFlags = CapabilitiesBitfield.init(
        lightpush = false,
        filter = false,
        store = false,
        relay = relay
      )

  let netConfigRes = NetConfig.init(
      bindIp = listenAddr,
      bindPort = Port(uint16(port)),
      extIp = extIp,
      extPort = extPort,
      wakuFlags = some(wakuFlags))

  if netConfigRes.isErr():
    errorResp = "Error creating NetConfig: " & $netConfigRes.error
    return false

  netConfig = netConfigRes.value

  return true
