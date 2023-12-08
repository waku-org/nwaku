

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
  ../events/[json_error_event,json_base_event]

proc parsePrivateKey(jsonNode: JsonNode,
                     privateKey: var PrivateKey,
                     jsonResp: var JsonEvent): bool =

  if not jsonNode.contains("key"):
    jsonResp = JsonErrorEvent.new("The node key is missing.");
    return false

  if jsonNode["key"].kind != JsonNodeKind.JString:
    jsonResp = JsonErrorEvent.new("The node key should be a string.");
    return false

  let key = jsonNode["key"].getStr()

  try:
    let skPrivKey = SkPrivateKey.init(crypto.fromHex(key)).tryGet()
    privateKey = crypto.PrivateKey(scheme: Secp256k1, skkey: skPrivKey)
  except CatchableError:
    let msg = "Invalid node key: " & getCurrentExceptionMsg()
    jsonResp = JsonErrorEvent.new(msg)
    return false

  return true

proc parseListenAddr(jsonNode: JsonNode,
                     listenAddr: var ValidIpAddress,
                     jsonResp: var JsonEvent): bool =

  if not jsonNode.contains("host"):
    jsonResp = JsonErrorEvent.new("host attribute is required")
    return false

  if jsonNode["host"].kind != JsonNodeKind.JString:
    jsonResp = JsonErrorEvent.new("The node host should be a string.");
    return false

  let host = jsonNode["host"].getStr()

  try:
    listenAddr = ValidIpAddress.init(host)
  except CatchableError:
    let msg = "Invalid host IP address: " & getCurrentExceptionMsg()
    jsonResp = JsonErrorEvent.new(msg)
    return false

  return true

proc parsePort(jsonNode: JsonNode,
               port: var int,
               jsonResp: var JsonEvent): bool =

  if not jsonNode.contains("port"):
    jsonResp = JsonErrorEvent.new("port attribute is required")
    return false

  if jsonNode["port"].kind != JsonNodeKind.JInt:
    jsonResp = JsonErrorEvent.new("The node port should be an integer.");
    return false

  port = jsonNode["port"].getInt()

  return true

proc parseRelay(jsonNode: JsonNode,
                relay: var bool,
                jsonResp: var JsonEvent): bool =

  if not jsonNode.contains("relay"):
    jsonResp = JsonErrorEvent.new("relay attribute is required")
    return false

  if jsonNode["relay"].kind != JsonNodeKind.JBool:
    jsonResp = JsonErrorEvent.new("The relay config param should be a boolean");
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
                jsonResp: var JsonEvent): bool =

  if not jsonNode.contains("store"):
    ## the store parameter is not required. By default is is disabled
    store = false
    return true

  if jsonNode["store"].kind != JsonNodeKind.JBool:
    jsonResp = JsonErrorEvent.new("The store config param should be a boolean");
    return false

  store = jsonNode["store"].getBool()

  if jsonNode.contains("storeNode"):
    if jsonNode["storeNode"].kind != JsonNodeKind.JString:
      jsonResp = JsonErrorEvent.new("The storeNode config param should be a string");
      return false

    storeNode = jsonNode["storeNode"].getStr()

  if jsonNode.contains("storeRetentionPolicy"):
    if jsonNode["storeRetentionPolicy"].kind != JsonNodeKind.JString:
      jsonResp = JsonErrorEvent.new("The storeRetentionPolicy config param should be a string");
      return false

    storeRetentionPolicy = jsonNode["storeRetentionPolicy"].getStr()

  if jsonNode.contains("storeDbUrl"):
    if jsonNode["storeDbUrl"].kind != JsonNodeKind.JString:
      jsonResp = JsonErrorEvent.new("The storeDbUrl config param should be a string");
      return false

    storeDbUrl = jsonNode["storeDbUrl"].getStr()

  if jsonNode.contains("storeVacuum"):
    if jsonNode["storeVacuum"].kind != JsonNodeKind.JBool:
      jsonResp = JsonErrorEvent.new("The storeVacuum config param should be a bool");
      return false

    storeVacuum = jsonNode["storeVacuum"].getBool()

  if jsonNode.contains("storeDbMigration"):
    if jsonNode["storeDbMigration"].kind != JsonNodeKind.JBool:
      jsonResp = JsonErrorEvent.new("The storeDbMigration config param should be a bool");
      return false

    storeDbMigration = jsonNode["storeDbMigration"].getBool()

  if jsonNode.contains("storeMaxNumDbConnections"):
    if jsonNode["storeMaxNumDbConnections"].kind != JsonNodeKind.JInt:
      jsonResp = JsonErrorEvent.new("The storeMaxNumDbConnections config param should be an int");
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
                  jsonResp: var JsonEvent): bool =

  if configNodeJson.len == 0:
    jsonResp = JsonErrorEvent.new("The configNodeJson is empty")
    return false

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(configNodeJson)
  except JsonParsingError:
    jsonResp = JsonErrorEvent.new("Exception: " & getCurrentExceptionMsg())
    return false

  # key
  if not parsePrivateKey(jsonNode, privateKey, jsonResp):
    return false

  # listenAddr
  var listenAddr = ValidIpAddress.init("127.0.0.1")
  if not parseListenAddr(jsonNode, listenAddr, jsonResp):
    return false

  # port
  var port = 0
  if not parsePort(jsonNode, port, jsonResp):
    return false

  let natRes = setupNat("any", clientId,
                        Port(uint16(port)),
                        Port(uint16(port)))
  if natRes.isErr():
    jsonResp = JsonErrorEvent.new(fmt"failed to setup NAT: {$natRes.error}")
    return false

  let (extIp, extTcpPort, _) = natRes.get()

  let extPort = if extIp.isSome() and extTcpPort.isNone():
                  some(Port(uint16(port)))
                else:
                  extTcpPort

  # relay
  if not parseRelay(jsonNode, relay, jsonResp):
    return false

  # topics
  parseTopics(jsonNode, topics)

  # store
  if not parseStore(jsonNode, store, storeNode, storeRetentionPolicy, storeDbUrl,
                    storeVacuum, storeDbMigration, storeMaxNumDbConnections, jsonResp):
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
    let msg = "Error creating NetConfig: " & $netConfigRes.error
    jsonResp = JsonErrorEvent.new(msg)
    return false

  netConfig = netConfigRes.value

  return true
