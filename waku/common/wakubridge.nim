import
  std/[tables, hashes, sequtils],
  chronos, confutils, chronicles, chronicles/topics_registry, 
  metrics, metrics/chronos_httpserver,
  stew/[byteutils, objects],
  stew/shims/net as stewNet, json_rpc/rpcserver,
  # Waku v1 imports
  eth/[keys, p2p], eth/common/utils,
  eth/p2p/enode,
  ../v1/protocol/waku_protocol,
  # Waku v2 imports
  libp2p/crypto/crypto,
  ../v2/protocol/waku_filter/waku_filter_types,
  ../v2/node/wakunode2,
  # Common cli config
  ./config_bridge

declarePublicCounter waku_bridge_transfers, "Number of messages transferred between Waku v1 and v2 networks", ["type"]
declarePublicCounter waku_bridge_dropped, "Number of messages dropped", ["type"]

logScope:
  topics = "wakubridge"

##################
# Default values #
##################

const
  ClientIdV1 = "nim-waku v1 node"
  DefaultTTL = 5'u32
  DeduplQSize = 20  # Maximum number of seen messages to keep in deduplication queue

#########
# Types #
#########

type
  WakuBridge* = ref object of RootObj
    nodev1*: EthereumNode
    nodev2*: WakuNode
    nodev2PubsubTopic: wakunode2.Topic # Pubsub topic to bridge to/from
    seen: seq[hashes.Hash] # FIFO queue of seen WakuMessages. Used for deduplication.

###################
# Helper funtions #
###################

proc containsOrAdd(sequence: var seq[hashes.Hash], hash: hashes.Hash): bool =
  if sequence.contains(hash):
    return true 

  if sequence.len >= DeduplQSize:
    trace "Deduplication queue full. Removing oldest item."
    sequence.delete 0, 0  # Remove first item in queue
  
  sequence.add(hash)

  return false

func toWakuMessage(env: Envelope): WakuMessage =
  # Translate a Waku v1 envelope to a Waku v2 message
  WakuMessage(payload: env.data,
              contentTopic: ContentTopic(string.fromBytes(env.topic)),
              version: 1)

proc toWakuV2(bridge: WakuBridge, env: Envelope) {.async.} =
  let msg = env.toWakuMessage()

  if bridge.seen.containsOrAdd(msg.encode().buffer.hash()):
    # This is a duplicate message. Return
    trace "Already seen. Dropping.", msg=msg
    waku_bridge_dropped.inc(labelValues = ["duplicate"])
    return
  
  trace "Sending message to V2", msg=msg

  waku_bridge_transfers.inc(labelValues = ["v1_to_v2"])
  
  await bridge.nodev2.publish(bridge.nodev2PubsubTopic, msg)

proc toWakuV1(bridge: WakuBridge, msg: WakuMessage) {.gcsafe.} =
  if bridge.seen.containsOrAdd(msg.encode().buffer.hash()):
    # This is a duplicate message. Return
    trace "Already seen. Dropping.", msg=msg
    waku_bridge_dropped.inc(labelValues = ["duplicate"])
    return

  trace "Sending message to V1", msg=msg

  waku_bridge_transfers.inc(labelValues = ["v2_to_v1"])

  # @TODO: use namespacing to map v2 contentTopics to v1 topics
  let v1TopicSeq = msg.contentTopic.toBytes()[0..3]
  
  discard bridge.nodev1.postMessage(ttl = DefaultTTL,
                                    topic = toArray(4, v1TopicSeq),
                                    payload = msg.payload)

##############
# Public API #
##############
proc new*(T: type WakuBridge,
          # NodeV1 initialisation
          nodev1Key: keys.KeyPair,
          nodev1Address: Address,
          powRequirement = 0.002,
          rng: ref BrHmacDrbgContext,
          topicInterest = none(seq[waku_protocol.Topic]),
          bloom = some(fullBloom()),
          # NodeV2 initialisation
          nodev2Key: crypto.PrivateKey,
          nodev2BindIp: ValidIpAddress, nodev2BindPort: Port,
          nodev2ExtIp = none[ValidIpAddress](), nodev2ExtPort = none[Port](),
          # Bridge configuration
          nodev2PubsubTopic: wakunode2.Topic): T =

  # Setup Waku v1 node
  var
    nodev1 = newEthereumNode(keys = nodev1Key, address = nodev1Address,
                             networkId = NetworkId(1), chain = nil, clientId = ClientIdV1,
                             addAllCapabilities = false, rng = rng)
  
  nodev1.addCapability Waku # Always enable Waku protocol

  # Setup the Waku configuration.
  # This node is being set up as a bridge. By default it gets configured as a node with
  # a full bloom filter so that it will receive and forward all messages.
  # It is, however, possible to configure a topic interest to bridge only
  # selected messages.
  # TODO: What is the PoW setting now?
  let wakuConfig = WakuConfig(powRequirement: powRequirement,
                              bloom: bloom, isLightNode: false,
                              maxMsgSize: waku_protocol.defaultMaxMsgSize,
                              topics: topicInterest)
  nodev1.configureWaku(wakuConfig)

  # Setup Waku v2 node
  let
    nodev2 = WakuNode.init(nodev2Key,
                           nodev2BindIp, nodev2BindPort,
                           nodev2ExtIp, nodev2ExtPort)
  
  return WakuBridge(nodev1: nodev1, nodev2: nodev2, nodev2PubsubTopic: nodev2PubsubTopic)

proc start*(bridge: WakuBridge) {.async.} =
  info "Starting WakuBridge"

  debug "Start listening on Waku v1"
  # Start listening on Waku v1 node
  let connectedFut = bridge.nodev1.connectToNetwork(@[],
    true, # Always enable listening
    false # Disable discovery (only discovery v4 is currently supported)
    )
  connectedFut.callback = proc(data: pointer) {.gcsafe.} =
    {.gcsafe.}:
      if connectedFut.failed:
        fatal "connectToNetwork failed", msg = connectedFut.readError.msg
        quit(1)
  
  # Start Waku v2 node
  debug "Start listening on Waku v2"
  await bridge.nodev2.start()
  
  # Always mount relay for bridge.
  # `triggerSelf` is false on a `bridge` to avoid duplicates
  bridge.nodev2.mountRelay(triggerSelf = false)

  # Bridging
  # Handle messages on Waku v1 and bridge to Waku v2  
  proc handleEnvReceived(envelope: Envelope) {.gcsafe, raises: [Defect].} =
    trace "Bridging envelope from V1 to V2", envelope=envelope
    asyncSpawn bridge.toWakuV2(envelope)

  bridge.nodev1.registerEnvReceivedHandler(handleEnvReceived)

  # Handle messages on Waku v2 and bridge to Waku v1
  proc relayHandler(pubsubTopic: string, data: seq[byte]) {.async, gcsafe.} =
    let msg = WakuMessage.init(data)
    if msg.isOk():
      trace "Bridging message from V2 to V1", msg=msg[]
      bridge.toWakuV1(msg[])
  
  bridge.nodev2.subscribe(bridge.nodev2PubsubTopic, relayHandler)

proc stop*(bridge: WakuBridge) {.async.} =
  await bridge.nodev2.stop()

when isMainModule:
  import
    eth/p2p/whispernodes,
    ./utils/nat,
    ../v1/node/rpc/wakusim,
    ../v1/node/rpc/waku,
    ../v1/node/rpc/key_storage,
    ../v1/node/waku_helpers,
    ../v2/node/jsonrpc/[debug_api,
                        filter_api,
                        relay_api,
                        store_api]

  proc startV2Rpc(node: WakuNode, rpcServer: RpcHttpServer, conf: WakuNodeConf) =
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
    rng = keys.newRng()
    conf = WakuNodeConf.load()
  
  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  # Load address configuration
  let
    (nodev1ExtIp, _, _) = setupNat(conf.nat, ClientIdV1,
                                   Port(conf.devp2pTcpPort + conf.portsShift),
                                   Port(conf.udpPort + conf.portsShift))
    # TODO: EthereumNode should have a better split of binding address and
    # external address. Also, can't have different ports as it stands now.
    nodev1Address = if nodev1ExtIp.isNone():
                      Address(ip: parseIpAddress("0.0.0.0"),
                              tcpPort: Port(conf.devp2pTcpPort + conf.portsShift),
                              udpPort: Port(conf.udpPort + conf.portsShift))
                    else:
                      Address(ip: nodev1ExtIp.get(),
                              tcpPort: Port(conf.devp2pTcpPort + conf.portsShift),
                              udpPort: Port(conf.udpPort + conf.portsShift))
    (nodev2ExtIp, nodev2ExtPort, _) = setupNat(conf.nat, clientId,
                                               Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                                               Port(uint16(conf.udpPort) + conf.portsShift))
  
  # Topic interest and bloom
  var topicInterest: Option[seq[waku_protocol.Topic]]
  var bloom: Option[Bloom]
  
  if conf.wakuV1TopicInterest:
    var topics: seq[waku_protocol.Topic]
    topicInterest = some(topics)
  else:
    bloom = some(fullBloom())

  let
    bridge = WakuBridge.new(nodev1Key = conf.nodekeyV1,
                            nodev1Address = nodev1Address,
                            powRequirement = conf.wakuV1Pow,
                            rng = rng,
                            topicInterest = topicInterest,
                            bloom = bloom,
                            nodev2Key = conf.nodekeyV2,
                            nodev2BindIp = conf.listenAddress, nodev2BindPort = Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                            nodev2ExtIp = nodev2ExtIp, nodev2ExtPort = nodev2ExtPort,
                            nodev2PubsubTopic = conf.bridgePubsubTopic)
  
  waitFor bridge.start()

  # Now load rest of config
  # Optionally direct connect nodev1 with a set of nodes

  if conf.staticnodesV1.len > 0: connectToNodes(bridge.nodev1, conf.staticnodesV1)
  elif conf.fleetV1 == prod: connectToNodes(bridge.nodev1, WhisperNodes)
  elif conf.fleetV1 == staging: connectToNodes(bridge.nodev1, WhisperNodesStaging)
  elif conf.fleetV1 == test: connectToNodes(bridge.nodev1, WhisperNodesTest)

  # Mount configured Waku v2 protocols
  mountLibp2pPing(bridge.nodev2)
  
  if conf.store:
    mountStore(bridge.nodev2, persistMessages = false)  # Bridge does not persist messages

  if conf.filter:
    mountFilter(bridge.nodev2)

  if conf.staticnodesV2.len > 0:
    waitFor connectToNodes(bridge.nodev2, conf.staticnodesV2)

  if conf.storenode != "":
    setStorePeer(bridge.nodev2, conf.storenode)

  if conf.filternode != "":
    setFilterPeer(bridge.nodev2, conf.filternode)

  if conf.rpc:
    let ta = initTAddress(conf.rpcAddress,
      Port(conf.rpcPort + conf.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    # Waku v1 RPC
    let keys = newKeyStorage()
    setupWakuRPC(bridge.nodev1, keys, rpcServer, rng)
    setupWakuSimRPC(bridge.nodev1, rpcServer)
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
