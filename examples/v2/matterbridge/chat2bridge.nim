import
  std/[tables, times, strutils],
  chronos, confutils, chronicles, chronicles/topics_registry, metrics,
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

logScope:
  topics = "chat2bridge"

##################
# Default values #
##################

const
  DefaultTopic* = chat2.DefaultTopic
  DefaultContentTopic* = chat2.DefaultContentTopic

#########
# Types #
#########

type
  Chat2MatterBridge* = ref object of RootObj
    mbClient*: MatterbridgeClient
    nodev2*: WakuNode
    running: bool
    pollPeriod: chronos.Duration
  
  MbMessageHandler* = proc (jsonNode: JsonNode) {.gcsafe.}

###################
# Helper funtions #
###################S

proc toWakuMessage(jsonNode: JsonNode): WakuMessage =
  # Translates a Matterbridge API JSON response to a Waku v2 message
  let msgFields = jsonNode.getFields()

  # @TODO error handling here - verify expected fields

  let chat2pb = Chat2Message(timestamp: getTime().toUnix(), # @TODO use provided timestamp
                             nick: msgFields["username"].getStr(),
                             payload: msgFields["text"].getStr().toBytes()).encode()

  WakuMessage(payload: chat2pb.buffer,
              contentTopic: DefaultContentTopic,
              version: 0)

proc toChat2(cmb: Chat2MatterBridge, jsonNode: JsonNode) {.async.} =
  chat2_mb_transfers.inc(labelValues = ["v1_to_v2"])

  trace "Post Matterbridge message to chat2"

  await cmb.nodev2.publish(DefaultTopic, jsonNode.toWakuMessage())

proc toMatterbridge(cmb: Chat2MatterBridge, msg: WakuMessage) {.gcsafe.} =
  chat2_mb_transfers.inc(labelValues = ["v2_to_v1"])

  trace "Post chat2 message to Matterbridge"

  let chat2Msg = Chat2Message.init(msg.payload)

  assert chat2Msg.isOk

  cmb.mbClient.postMessage(text = string.fromBytes(chat2Msg[].payload),
                           username = chat2Msg[].nick)

proc pollMatterbridge(cmb: Chat2MatterBridge, handler: MbMessageHandler) {.async.} =
  while cmb.running:
    for jsonNode in cmb.mbClient.getMessages():
      handler(jsonNode)
    
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
          nodev2ExtIp = none[ValidIpAddress](), nodev2ExtPort = none[Port]()): T =

  # Setup Matterbridge 
  let
    mbClient = MatterbridgeClient.new(mbHostUri, mbGateway)

  # Setup Waku v2 node
  let
    nodev2 = WakuNode.init(nodev2Key,
                           nodev2BindIp, nodev2BindPort,
                           nodev2ExtIp, nodev2ExtPort)
  
  return Chat2MatterBridge(mbClient: mbClient, nodev2: nodev2, running: false, pollPeriod: chronos.seconds(1))

proc start*(cmb: Chat2MatterBridge) {.async.} =
  info "Starting Chat2MatterBridge"

  cmb.running = true

  debug "Start polling Matterbridge"
  
  # Start Matterbridge polling (@TODO: use streaming interface)
  proc mbHandler(jsonNode: JsonNode) {.gcsafe.} =
    trace "Bridging message from Matterbridge to chat2", jsonNode=jsonNode
    waitFor cmb.toChat2(jsonNode)
  
  asyncSpawn cmb.pollMatterbridge(mbHandler)
  
  # Start Waku v2 node
  debug "Start listening on Waku v2"
  await cmb.nodev2.start()
  
  cmb.nodev2.mountRelay() # Always mount relay for bridge

  # Bridging
  # Handle messages on Waku v2 and bridge to Matterbridge
  proc relayHandler(pubsubTopic: string, data: seq[byte]) {.async, gcsafe.} =
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

  proc startV2Rpc(node: WakuNode, rpcServer: RpcHttpServer, conf: Chat2MatterbridgeConf) =
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
                            mbHostUri = conf.mbHostUri,
                            mbGateway = conf.mbGateway,
                            nodev2Key = conf.nodeKeyv2,
                            nodev2BindIp = conf.listenAddress, nodev2BindPort = Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                            nodev2ExtIp = nodev2ExtIp, nodev2ExtPort = nodev2ExtPort)
  
  waitFor bridge.start()

  # Now load rest of config
  # Mount configured Waku v2 protocols
  if conf.store:
    mountStore(bridge.nodev2)

  if conf.filter:
    mountFilter(bridge.nodev2)

  if conf.staticnodesv2.len > 0:
    waitFor connectToNodes(bridge.nodev2, conf.staticnodesv2)

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

  when defined(insecure):
    if conf.metricsServer:
      let
        address = conf.metricsServerAddress
        port = conf.metricsServerPort + conf.portsShift
      info "Starting metrics HTTP server", address, port
      metrics.startHttpServer($address, Port(port))

  runForever()
