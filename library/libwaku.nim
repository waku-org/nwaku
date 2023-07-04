
import
  std/[sequtils,times,strformat,json,options],
  strutils,
  os
import
  chronicles,
  chronos,
  libp2p/crypto/secp,
  stew/shims/net
import
  ../vendor/nim-libp2p/libp2p/crypto/crypto,
  ../../waku/common/utils/nat,
  ../../waku/v2/waku_enr/capabilities,
  ../../waku/v2/waku_core/message/codec,
  ../../waku/v2/waku_core/message/message,
  ../../waku/v2/waku_core/topics/pubsub_topic,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/node/builder,
  ../../waku/v2/node/config,
  ../../waku/v2/waku_relay/protocol,
  events/[json_error_event,json_message_event,json_signal_event]

################################################################################
### Wrapper around the waku node
################################################################################

################################################################################
### Exported types
type
  ConfigNode* {.exportc.} = object
    # Struct exported to C
    host*: cstring
    port*: uint
    key*: cstring
    relay*: bool

### End of exported types
################################################################################

################################################################################
### Not-exported components

type
  EventCallback = proc(signal: cstring) {.cdecl, gcsafe, raises: [Defect].}

var eventCallback:EventCallback = nil

proc relayEventCallback(pubsubTopic: string, data: seq[byte]): Future[void] {.gcsafe, raises: [Defect].} =
  # Callback that hadles the Waku Relay events. i.e. messages or errors.
  if not isNil(eventCallback):
    let msg = WakuMessage.decode(data)
    var event: JsonSignal
    if msg.isOk():
      event = JsonMessageEvent.new(pubsubTopic, msg.value)
    else:
      let errorMsg = string("Error decoding message.") & $msg.error
      event = JsonErrorEvent.new(errorMsg)

    try:
      eventCallback(cstring($event))
    except Exception:
      error "Exception when calling 'eventCallBack': " &
            getCurrentExceptionMsg()
  else:
    error "eventCallback is nil"

  var retFut = newFuture[void]()
  retFut.complete()
  return retFut

proc okResp(message: string): string =
  $(%* { "result": message })

proc errResp(message: string): string =
  # Convers an error message into an error-JsonResponse
  # {
  #   error: string;
  # }
  return $(%* { "error": message })

proc parseConfig(config: ConfigNode,
                 privateKey: var PrivateKey,
                 netConfig: var NetConfig,
                 jsonResp: var string
                 ): bool =
  if len(config.key) == 0:
    jsonResp = errResp("The node key is missing.");
    return false

  try:
    let key = SkPrivateKey.init(crypto.fromHex($config.key)).tryGet()
    privateKey = crypto.PrivateKey(scheme: Secp256k1, skkey: key)
  except CatchableError:
    let msg = string("Invalid node key: ") & getCurrentExceptionMsg()
    jsonResp = errResp(msg)
    return false

  if len(config.host) == 0:
    jsonResp = errResp("host attribute is required")
    return false

  var listenAddr = ValidIpAddress.init("127.0.0.1")
  try:
    listenAddr = ValidIpAddress.init($config.host)
  except CatchableError:
    let msg = string("Invalid host IP address: ") & getCurrentExceptionMsg()
    jsonResp = errResp(msg)
    return false

  if config.port == 0:
    jsonResp = errResp("Please set a valid port number")
    return false

  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport for libp2p traffic.
  let udpPort = config.port

  let natRes = setupNat("any", clientId,
                        Port(uint16(config.port)),
                        Port(uint16(udpPort)))
  if natRes.isErr():
    jsonResp = errResp(fmt"failed to setup NAT: {$natRes.error}")
    return false

  let (extIp, extTcpPort, _) = natRes.get()

  let extPort = if extIp.isSome() and extTcpPort.isNone():
                  some(Port(uint16(config.port)))
                else:
                  extTcpPort

  let wakuFlags = CapabilitiesBitfield.init(
        lightpush = false,
        filter = false,
        store = false,
        relay = config.relay
      )

  let netConfigRes = NetConfig.init(
      bindIp = listenAddr,
      bindPort = Port(uint16(config.port)),
      extIp = extIp,
      extPort = extPort,
      wakuFlags = some(wakuFlags))

  if netConfigRes.isErr():
    let msg = string("Error creating NetConfig: ") & $netConfigRes.error
    jsonResp = errResp(msg)
    return false

  netConfig = netConfigRes.value

  return true

# WakuNode instance
var node {.threadvar.}: WakuNode

### End of not-exported components
################################################################################

################################################################################
### Exported procs

proc waku_new(config: ConfigNode,
              jsonResp: var string): bool
              {.dynlib, exportc.} =
# Creates a new instance of the WakuNode.
# Notice that the ConfigNode type is also exported and available for users.
  var privateKey: PrivateKey
  var netConfig = NetConfig.init(ValidIpAddress.init("127.0.0.1"), Port(60000'u16)).value
  if not parseConfig(config,
                     privateKey, netConfig,
                     jsonResp):
    return false

  var builder = WakuNodeBuilder.init()
  builder.withRng(crypto.newRng())
  builder.withNodeKey(privateKey)
  builder.withNetworkConfiguration(netConfig)
  builder.withSwitchConfiguration(
    maxConnections = some(50.int)
  )

  let wakuNodeRes = builder.build()
  if wakuNodeRes.isErr():
    let errorMsg = string("failed to create waku node instance: ") & wakuNodeRes.error
    jsonResp = errResp(errorMsg)
    return false

  node = wakuNodeRes.value

  if config.relay:
    waitFor node.mountRelay()
    node.peerManager.start()

  return true

proc waku_version(): cstring {.dynlib, exportc.} =
  return WakuNodeVersionString

proc waku_set_event_callback(callback: EventCallback) {.dynlib, exportc.} =
  eventCallback = callback

proc waku_content_topic(appName: cstring,
                        appVersion: uint,
                        contentTopicName: cstring,
                        encoding: cstring,
                        outContentTopic: var string) {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding
  outContentTopic = fmt"{appName}/{appVersion}/{contentTopicName}/{encoding}"

proc waku_pubsub_topic(topicName: cstring, outPubsubTopic: var string) {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding
  outPubsubTopic = fmt"/waku/2/{topicName}"

proc waku_default_pubsub_topic(defPubsubTopic: var string) {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic
  defPubsubTopic = DefaultPubsubTopic

proc waku_relay_publish(pubSubTopic: cstring,
                        jsonWakuMessage: cstring,
                        timeoutMs: int,
                        jsonResp: var string): bool

                        {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms

  var jsonContent:JsonNode
  try:
    jsonContent = parseJson($jsonWakuMessage)
  except JsonParsingError:
    jsonResp = errResp (fmt"Problem parsing json message. {getCurrentExceptionMsg()}")
    return false

  var wakuMessage: WakuMessage
  try:
    var version = 0'u32
    if jsonContent.hasKey("version"):
      version = (uint32) jsonContent["version"].getInt()

    wakuMessage = WakuMessage(
        # Visit https://rfc.vac.dev/spec/14/ for further details
        payload: jsonContent["payload"].getStr().toSeq().mapIt(byte (it)),
        contentTopic: $jsonContent["content_topic"].getStr(),
        version: version,
        timestamp: getTime().toUnix(),
        ephemeral: false
    )
  except KeyError:
    jsonResp = errResp(fmt"Problem building the WakuMessage. {getCurrentExceptionMsg()}")
    return false

  let targetPubSubTopic = if $pubSubTopic == "":
                            DefaultPubsubTopic
                          else:
                            $pubSubTopic

  if node.wakuRelay.isNil():
    jsonResp = errResp("Can't publish. WakuRelay is not enabled.")
    return false

  let pubMsgFut = node.wakuRelay.publish(targetPubSubTopic, wakuMessage)

  # With the next loop we convert an asynchronous call into a synchronous one
  for i in 0 .. timeoutMs:
    if pubMsgFut.finished():
      break
    sleep(1)

  if pubMsgFut.finished():
    let numPeers = pubMsgFut.read()
    if numPeers == 0:
      jsonResp = errResp("Message not sent because no peers found")
    elif numPeers > 0:
      # TODO: pending to return a valid message Id (response when all is correct)
      jsonResp = okResp("hard-coded-message-id")

  else:
    jsonResp = errResp("Timeout expired")

  return true

proc waku_start() {.dynlib, exportc.} =
  waitFor node.start()

proc waku_stop() {.dynlib, exportc.} =
  waitFor node.stop()

proc waku_relay_subscribe(
                pubSubTopic: cstring,
                jsonResp: var string): bool
                {.dynlib, exportc.} =
  # @params
  #  topic: Pubsub topic to subscribe to. If empty, it subscribes to the default pubsub topic.
  if isNil(eventCallback):
    jsonResp = errResp("""Cannot subscribe without a callback.
Kindly set it with the 'waku_set_event_callback' function""")
    return false

  if node.wakuRelay.isNil():
    jsonResp = errResp("Cannot subscribe without Waku Relay enabled.")
    return false

  node.wakuRelay.subscribe(PubsubTopic($pubSubTopic), PubsubRawHandler(relayEventCallback))

  jsonResp = okResp("true")
  return true

proc waku_relay_unsubscribe(
                pubSubTopic: cstring,
                jsonResp: var string): bool
                {.dynlib, exportc.} =
  # @params
  #  topic: Pubsub topic to subscribe to. If empty, it unsubscribes to the default pubsub topic.
  if isNil(eventCallback):
    jsonResp = errResp("""Cannot unsubscribe without a callback.
Kindly set it with the 'waku_set_event_callback' function""")
    return false

  if node.wakuRelay.isNil():
    jsonResp = errResp("Cannot unsubscribe without Waku Relay enabled.")
    return false

  node.wakuRelay.unsubscribeAll(PubsubTopic($pubSubTopic))

  jsonResp = okResp("true")
  return true

proc waku_connect(peerMultiAddr: cstring,
                  timeoutMs: uint = 10000,
                  jsonResp: var string): bool
                  {.dynlib, exportc.} =
  # peerMultiAddr: comma-separated list of fully-qualified multiaddresses.
  let peers = ($peerMultiAddr).split(",").mapIt(strip(it))

  # TODO: the timeoutMs is not being used at all!
  let connectFut = node.connectToNodes(peers, source="static")
  while not connectFut.finished():
    poll()

  if not connectFut.completed():
    jsonResp = errResp("Timeout expired.")
    return false

  return true

proc waku_poll() {.dynlib, exportc, gcsafe.} =
  poll()

### End of exported procs
################################################################################