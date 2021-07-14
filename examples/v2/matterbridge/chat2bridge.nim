import
  std/[tables, times, strutils, hashes, sequtils],
  chronos, confutils, chronicles, chronicles/topics_registry, 
  metrics, metrics/chronos_httpserver,
  stew/[byteutils, endians2],
  stew/shims/net as stewNet, json_rpc/rpcserver,
  # Matterbridge client imports
  ../../../waku/common/utils/matterbridge_client,
  # Waku v2 imports
  libp2p/crypto/crypto,
  ../../../waku/v2/protocol/waku_filter/waku_filter_types,
  ../../../waku/v2/node/wakunode2,
  # Chat 2 imports
  ../chat2,
  # Common cli config
  ./config_chat2bridge

declarePublicCounter chat2_mb_transfers, "Number of messages transferred between chat2 and Matterbridge", ["type"]
declarePublicCounter chat2_mb_dropped, "Number of messages dropped", ["reason"]

logScope:
  topics = "chat2bridge"

##################
# Default values #
##################

const
  DefaultTopic* = chat2.DefaultTopic
  DeduplQSize = 20  # Maximum number of seen messages to keep in deduplication queue

#########
# Types #
#########

type
  Chat2MatterBridge* = ref object of RootObj
    mbClient*: MatterbridgeClient
    nodev2*: WakuNode
    running: bool
    pollPeriod: chronos.Duration
    seen: seq[Hash] #FIFO queue
    contentTopic: string
  
  MbMessageHandler* = proc (jsonNode: JsonNode) {.gcsafe.}

###################
# Helper funtions #
###################S

proc containsOrAdd(sequence: var seq[Hash], hash: Hash): bool =
  if sequence.contains(hash):
    return true 

  if sequence.len >= DeduplQSize:
    trace "Deduplication queue full. Removing oldest item."
    sequence.delete 0, 0  # Remove first item in queue
  
  sequence.add(hash)

  return false

proc toWakuMessage(cmb: Chat2MatterBridge, jsonNode: JsonNode): WakuMessage {.raises: [Defect, KeyError]} =
  # Translates a Matterbridge API JSON response to a Waku v2 message
  let msgFields = jsonNode.getFields()

  # @TODO error handling here - verify expected fields

  let chat2pb = Chat2Message(timestamp: getTime().toUnix(), # @TODO use provided timestamp
                             nick: msgFields["username"].getStr(),
                             payload: msgFields["text"].getStr().toBytes()).encode()

  WakuMessage(payload: chat2pb.buffer,
              contentTopic: cmb.contentTopic,
              version: 0)

proc toChat2(cmb: Chat2MatterBridge, jsonNode: JsonNode) {.async.} =
  let msg = cmb.toWakuMessage(jsonNode)

  if cmb.seen.containsOrAdd(msg.payload.hash()):
    # This is a duplicate message. Return.
    chat2_mb_dropped.inc(labelValues = ["duplicate"])
    return

  trace "Post Matterbridge message to chat2"
  
  chat2_mb_transfers.inc(labelValues = ["mb_to_chat2"])

  await cmb.nodev2.publish(DefaultTopic, msg)

proc toMatterbridge(cmb: Chat2MatterBridge, msg: WakuMessage) {.gcsafe, raises: [Exception].} =
  if cmb.seen.containsOrAdd(msg.payload.hash()):
    # This is a duplicate message. Return.
    chat2_mb_dropped.inc(labelValues = ["duplicate"])
    return

  if msg.contentTopic != cmb.contentTopic:
    # Only bridge messages on the configured content topic
    chat2_mb_dropped.inc(labelValues = ["filtered"])
    return

  trace "Post chat2 message to Matterbridge"

  chat2_mb_transfers.inc(labelValues = ["chat2_to_mb"])

  let chat2Msg = Chat2Message.init(msg.payload)

  assert chat2Msg.isOk

  try:
    cmb.mbClient.postMessage(text = string.fromBytes(chat2Msg[].payload),
                             username = chat2Msg[].nick)
  except OSError, IOError, TimeoutError:
    chat2_mb_dropped.inc(labelValues = ["duplicate"])
    error "Matterbridge host unreachable. Dropping message."

proc pollMatterbridge(cmb: Chat2MatterBridge, handler: MbMessageHandler) {.async.} =
  while cmb.running:
    try:
      for jsonNode in cmb.mbClient.getMessages():
        handler(jsonNode)
    except OSError, IOError:
      error "Matterbridge host unreachable. Sleeping before retrying."
      await sleepAsync(chronos.seconds(10))

    await sleepAsync(cmb.pollPeriod)

##############
# Public API #
##############
proc new*(T: type Chat2MatterBridge,
          # Matterbridge initialisation
          mbHostUri: string,
          mbGateway: string,
          # NodeV2 initialisation
          nodev2Key: crypto.PrivateKey,
          nodev2BindIp: ValidIpAddress, nodev2BindPort: Port,
          nodev2ExtIp = none[ValidIpAddress](), nodev2ExtPort = none[Port](),
          contentTopic: string): T =

  # Setup Matterbridge 
  let
    mbClient = MatterbridgeClient.new(mbHostUri, mbGateway)
  
  # Let's verify the Matterbridge configuration before continuing
  try:
    if mbClient.isHealthy():
      info "Reached Matterbridge host", host=mbClient.host
    else:
      raise newException(ValueError, "Matterbridge client not healthy")
  except OSError, IOError:
    raise newException(ValueError, "Matterbridge host unreachable")

  # Setup Waku v2 node
  let
    nodev2 = WakuNode.new(nodev2Key,
                           nodev2BindIp, nodev2BindPort,
                           nodev2ExtIp, nodev2ExtPort)
  
  return Chat2MatterBridge(mbClient: mbClient,
                           nodev2: nodev2,
                           running: false,
                           pollPeriod: chronos.seconds(1),
                           contentTopic: contentTopic)

proc start*(cmb: Chat2MatterBridge) {.async.} =
  info "Starting Chat2MatterBridge"

  cmb.running = true

  debug "Start polling Matterbridge"
  
  # Start Matterbridge polling (@TODO: use streaming interface)
  proc mbHandler(jsonNode: JsonNode) {.gcsafe, raises: [Exception].} =
    trace "Bridging message from Matterbridge to chat2", jsonNode=jsonNode
    waitFor cmb.toChat2(jsonNode)
  
  asyncSpawn cmb.pollMatterbridge(mbHandler)
  
  # Start Waku v2 node
  debug "Start listening on Waku v2"
  await cmb.nodev2.start()
  
  # Always mount relay for bridge
  # `triggerSelf` is false on a `bridge` to avoid duplicates
  cmb.nodev2.mountRelay(triggerSelf = false)

  # Bridging
  # Handle messages on Waku v2 and bridge to Matterbridge
  proc relayHandler(pubsubTopic: string, data: seq[byte]) {.async, gcsafe, raises: [Defect].} =
    let msg = WakuMessage.init(data)
    if msg.isOk():
      trace "Bridging message from Chat2 to Matterbridge", msg=msg[]
      cmb.toMatterbridge(msg[])
  
  cmb.nodev2.subscribe(DefaultTopic, relayHandler)

proc stop*(cmb: Chat2MatterBridge) {.async.} =
  info "Stopping Chat2MatterBridge"
  
  cmb.running = false

  await cmb.nodev2.stop()

when isMainModule:
  import
    ../../../waku/common/utils/nat,
    ../../../waku/v2/node/jsonrpc/[debug_api,
                                  filter_api,
                                  relay_api,
                                  store_api]

  proc startV2Rpc(node: WakuNode, rpcServer: RpcHttpServer, conf: Chat2MatterbridgeConf) {.raises: [Exception].} =
    installDebugApiHandlers(node, rpcServer)

    # Install enabled API handlers:
    if conf.relay:
      let topicCache = newTable[string, seq[WakuMessage]]()
      installRelayApiHandlers(node, rpcServer, topicCache)
    
    if conf.filter:
      let messageCache = newTable[ContentTopic, seq[WakuMessage]]()
      installFilterApiHandlers(node, rpcServer, messageCache)
    
    if conf.store:
      installStoreApiHandlers(node, rpcServer)
    
    rpcServer.start()
  
  let
    rng = newRng()
    conf = Chat2MatterbridgeConf.load()
  
  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  # Load address configuration
  let
    (nodev2ExtIp, nodev2ExtPort, _) = setupNat(conf.nat, clientId,
                                               Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                                               Port(uint16(conf.udpPort) + conf.portsShift))

  let
    bridge = Chat2Matterbridge.new(
                            mbHostUri = "http://" & $initTAddress(conf.mbHostAddress, Port(conf.mbHostPort)),
                            mbGateway = conf.mbGateway,
                            nodev2Key = conf.nodekey,
                            nodev2BindIp = conf.listenAddress, nodev2BindPort = Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                            nodev2ExtIp = nodev2ExtIp, nodev2ExtPort = nodev2ExtPort,
                            contentTopic = conf.contentTopic)
  
  waitFor bridge.start()

  # Now load rest of config
  # Mount configured Waku v2 protocols
  mountLibp2pPing(bridge.nodev2)

  if conf.store:
    mountStore(bridge.nodev2)

  if conf.filter:
    mountFilter(bridge.nodev2)

  if conf.staticnodes.len > 0:
    waitFor connectToNodes(bridge.nodev2, conf.staticnodes)

  if conf.storenode != "":
    setStorePeer(bridge.nodev2, conf.storenode)

  if conf.filternode != "":
    setFilterPeer(bridge.nodev2, conf.filternode)

  if conf.rpc:
    let ta = initTAddress(conf.rpcAddress,
      Port(conf.rpcPort + conf.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    # Waku v2 rpc
    startV2Rpc(bridge.nodev2, rpcServer, conf)

    rpcServer.start()

  if conf.metricsServer:
    let
      address = conf.metricsServerAddress
      port = conf.metricsServerPort + conf.portsShift
    info "Starting metrics HTTP server", address, port
    startMetricsHttpServer($address, Port(port))

  runForever()
