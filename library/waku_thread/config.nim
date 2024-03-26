import std/[json, strformat, options]
import
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  stew/shims/net,
  ../../waku/waku_enr/capabilities,
  ../../waku/common/utils/nat,
  ../../waku/factory/external_config,
  ../../waku/node/waku_node,
  ../../waku/node/config,
  ../events/json_base_event

proc parsePrivateKey(
    jsonNode: JsonNode, conf: var WakuNodeConf, errorResp: var string
): bool =
  if not jsonNode.contains("key") or jsonNode["key"].kind == JsonNodeKind.JNull:
    conf.nodekey = some(PrivateKey.random(Secp256k1, newRng()[]).tryGet())
    return true

  if jsonNode["key"].kind != JsonNodeKind.JString:
    errorResp = "The node key should be a string."
    return false

  let key = jsonNode["key"].getStr()

  try:
    let skPrivKey = SkPrivateKey.init(crypto.fromHex(key)).tryGet()
    conf.nodekey = some(crypto.PrivateKey(scheme: Secp256k1, skkey: skPrivKey))
  except CatchableError:
    let msg = "Invalid node key: " & getCurrentExceptionMsg()
    errorResp = msg
    return false

  return true

proc parseListenAddr(
    jsonNode: JsonNode, conf: var WakuNodeConf, errorResp: var string
): bool =
  var listenAddr: IpAddress
  if not jsonNode.contains("host"):
    conf.listenAddress = defaultListenAddress()
    return true

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

proc parsePort(jsonNode: JsonNode, conf: var WakuNodeConf, errorResp: var string): bool =
  if not jsonNode.contains("port"):
    conf.tcpPort = Port(60000)
    return true

  if jsonNode["port"].kind != JsonNodeKind.JInt:
    errorResp = "The node port should be an integer."
    return false

  conf.tcpPort = Port(jsonNode["port"].getInt())

  return true

proc parseRelay(jsonNode: JsonNode, conf: var WakuNodeConf, errorResp: var string): bool =
  if not jsonNode.contains("relay"):
    errorResp = "relay attribute is required"
    return false

  if jsonNode["relay"].kind != JsonNodeKind.JBool:
    errorResp = "The relay config param should be a boolean"
    return false

  conf.relay = jsonNode["relay"].getBool()

  return true

proc parseStore(
    jsonNode: JsonNode,
    conf: var WakuNodeConf,
    errorResp: var string,
): bool =
  if not jsonNode.contains("store"):
    ## the store parameter is not required. By default is is disabled
    conf.store = false
    return true

  if jsonNode["store"].kind != JsonNodeKind.JBool:
    errorResp = "The store config param should be a boolean"
    return false

  conf.store = jsonNode["store"].getBool()

  if jsonNode.contains("storeNode"):
    if jsonNode["storeNode"].kind != JsonNodeKind.JString:
      errorResp = "The storeNode config param should be a string"
      return false

    conf.storeNode = jsonNode["storeNode"].getStr()

  if jsonNode.contains("storeRetentionPolicy"):
    if jsonNode["storeRetentionPolicy"].kind != JsonNodeKind.JString:
      errorResp = "The storeRetentionPolicy config param should be a string"
      return false

    conf.storeMessageRetentionPolicy = jsonNode["storeRetentionPolicy"].getStr()

  if jsonNode.contains("storeDbUrl"):
    if jsonNode["storeDbUrl"].kind != JsonNodeKind.JString:
      errorResp = "The storeDbUrl config param should be a string"
      return false

    conf.storeMessageDbUrl = jsonNode["storeDbUrl"].getStr()

  if jsonNode.contains("storeVacuum"):
    if jsonNode["storeVacuum"].kind != JsonNodeKind.JBool:
      errorResp = "The storeVacuum config param should be a bool"
      return false

    conf.storeMessageDbVacuum = jsonNode["storeVacuum"].getBool()

  if jsonNode.contains("storeDbMigration"):
    if jsonNode["storeDbMigration"].kind != JsonNodeKind.JBool:
      errorResp = "The storeDbMigration config param should be a bool"
      return false

    conf.storeMessageDbMigration = jsonNode["storeDbMigration"].getBool()

  if jsonNode.contains("storeMaxNumDbConnections"):
    if jsonNode["storeMaxNumDbConnections"].kind != JsonNodeKind.JInt:
      errorResp = "The storeMaxNumDbConnections config param should be an int"
      return false

    conf.storeMaxNumDbConnections = jsonNode["storeMaxNumDbConnections"].getInt()

  return true

proc parseTopics(jsonNode: JsonNode, conf: var WakuNodeConf) =
  if jsonNode.contains("pubsubTopics"):
    for topic in jsonNode["pubsubTopics"].items:
      conf.pubsubTopics.add(topic.getStr())
  else:
    conf.pubsubTopics = @["/waku/2/default-waku/proto"]

proc parseConfig*(
    configNodeJson: string,
    conf: var WakuNodeConf,
    errorResp: var string,
): bool {.raises: [].} =
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
    if not parsePrivateKey(jsonNode, conf, errorResp):
      return false
  except Exception, KeyError:
    errorResp = "Exception calling parsePrivateKey: " & getCurrentExceptionMsg()
    return false

  # listenAddr
  var listenAddr: IpAddress
  try:
    listenAddr = parseIpAddress("127.0.0.1")
    if not parseListenAddr(jsonNode, conf, errorResp):
      return false
  except Exception, ValueError:
    errorResp = "Exception calling parseIpAddress: " & getCurrentExceptionMsg()
    return false

  # port
  try:
    if not parsePort(jsonNode, conf, errorResp):
      return false
  except Exception, ValueError:
    errorResp = "Exception calling parsePort: " & getCurrentExceptionMsg()
    return false

  # relay
  try:
    if not parseRelay(jsonNode, conf, errorResp):
      return false
  except Exception, KeyError:
    errorResp = "Exception calling parseRelay: " & getCurrentExceptionMsg()
    return false

  # topics
  try:
    parseTopics(jsonNode, conf)
  except Exception, KeyError:
    errorResp = "Exception calling parseTopics: " & getCurrentExceptionMsg()
    return false

  # store
  try:
    if not parseStore(jsonNode, conf, errorResp):
      return false
  except Exception, KeyError:
    errorResp = "Exception calling parseStore: " & getCurrentExceptionMsg()
    return false

  return true
