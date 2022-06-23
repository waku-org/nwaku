{.push raises: [Defect].}

import
  std/[tables, hashes, sequtils],
  chronos, confutils, chronicles, chronicles/topics_registry, chronos/streams/tlsstream,
  metrics, metrics/chronos_httpserver,
  stew/byteutils,
  stew/shims/net as stewNet, json_rpc/rpcserver,
  # Waku v1 imports
  eth/[keys, p2p], eth/common/utils,
  eth/p2p/[enode, peer_pool],
  eth/p2p/discoveryv5/random2,
  ../v1/protocol/waku_protocol,
  # Waku v2 imports
  libp2p/crypto/crypto,
  libp2p/nameresolving/nameresolver,
  ../v2/utils/namespacing,
  ../v2/utils/time,
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
  ContentTopicApplication = "waku"
  ContentTopicAppVersion = "1"
  MaintenancePeriod = 1.minutes
  TargetV1Peers = 4  # Target number of v1 connections to maintain. Could be made configurable in future.

#########
# Types #
#########

type
  WakuBridge* = ref object of RootObj
    nodev1*: EthereumNode
    nodev2*: WakuNode
    nodev2PubsubTopic: wakunode2.Topic # Pubsub topic to bridge to/from
    seen: seq[hashes.Hash] # FIFO queue of seen WakuMessages. Used for deduplication.
    rng: ref BrHmacDrbgContext
    v1Pool: seq[Node] # Pool of v1 nodes for possible connections
    targetV1Peers: int # Target number of v1 peers to maintain
    started: bool # Indicates that bridge is running

###################
# Helper funtions #
###################

# Validity

proc isBridgeable*(msg: WakuMessage): bool =
  ## Determines if a Waku v2 msg is on a bridgeable content topic
  
  let ns = NamespacedTopic.fromString(msg.contentTopic)
  if ns.isOk():
    if ns.get().application == ContentTopicApplication and ns.get().version == ContentTopicAppVersion:
      return true
  
  return false

# Deduplication

proc containsOrAdd(sequence: var seq[hashes.Hash], hash: hashes.Hash): bool =
  if sequence.contains(hash):
    return true 

  if sequence.len >= DeduplQSize:
    trace "Deduplication queue full. Removing oldest item."
    sequence.delete 0, 0  # Remove first item in queue
  
  sequence.add(hash)

  return false

# Topic conversion

proc toV2ContentTopic*(v1Topic: waku_protocol.Topic): ContentTopic =
  ## Convert a 4-byte array v1 topic to a namespaced content topic
  ## with format `/waku/1/<v1-topic-bytes-as-hex>/rfc26`
  ## 
  ## <v1-topic-bytes-as-hex> should be prefixed with `0x`
  
  var namespacedTopic = NamespacedTopic()
  
  namespacedTopic.application = ContentTopicApplication
  namespacedTopic.version = ContentTopicAppVersion
  namespacedTopic.topicName = "0x" & v1Topic.toHex()
  namespacedTopic.encoding = "rfc26"

  return ContentTopic($namespacedTopic)

proc toV1Topic*(contentTopic: ContentTopic): waku_protocol.Topic {.raises: [Defect, LPError, ValueError]} =
  ## Extracts the 4-byte array v1 topic from a content topic
  ## with format `/waku/1/<v1-topic-bytes-as-hex>/rfc26`

  hexToByteArray(hexStr = NamespacedTopic.fromString(contentTopic).tryGet().topicName,
                 N = 4)  # Byte array length

# Message conversion

func toWakuMessage(env: waku_protocol.Envelope): WakuMessage =
  # Translate a Waku v1 envelope to a Waku v2 message
  WakuMessage(payload: env.data,
              contentTopic: toV2ContentTopic(env.topic),
              timestamp: (getNanosecondTime(env.expiry) - getNanosecondTime(env.ttl)),
              version: 1)

proc toWakuV2(bridge: WakuBridge, env: waku_protocol.Envelope) {.async.} =
  let msg = env.toWakuMessage()

  if bridge.seen.containsOrAdd(msg.encode().buffer.hash()):
    # This is a duplicate message. Return
    trace "Already seen. Dropping.", msg=msg
    waku_bridge_dropped.inc(labelValues = ["duplicate"])
    return
  
  trace "Sending message to V2", msg=msg

  waku_bridge_transfers.inc(labelValues = ["v1_to_v2"])
  
  await bridge.nodev2.publish(bridge.nodev2PubsubTopic, msg)

proc toWakuV1(bridge: WakuBridge, msg: WakuMessage) {.gcsafe, raises: [Defect, LPError, ValueError].} =
  if bridge.seen.containsOrAdd(msg.encode().buffer.hash()):
    # This is a duplicate message. Return
    trace "Already seen. Dropping.", msg=msg
    waku_bridge_dropped.inc(labelValues = ["duplicate"])
    return

  trace "Sending message to V1", msg=msg

  waku_bridge_transfers.inc(labelValues = ["v2_to_v1"])

  # @TODO: use namespacing to map v2 contentTopics to v1 topics
  let v1TopicSeq = msg.contentTopic.toBytes()[0..3]

  case msg.version:
  of 1:
    discard bridge.nodev1.postEncoded(ttl = DefaultTTL,
                                      topic = toV1Topic(msg.contentTopic),
                                      encodedPayload = msg.payload) # The payload is already encoded according to https://rfc.vac.dev/spec/26/
  else:
    discard bridge.nodev1.postMessage(ttl = DefaultTTL,
                                      topic = toV1Topic(msg.contentTopic),
                                      payload = msg.payload)

proc connectToV1(bridge: WakuBridge, target: int) =
  ## Uses the initialised peer pool to attempt to connect
  ## to the set target number of v1 peers at random.

  # First filter the peers in the pool that we're not yet connected to
  var candidates = bridge.v1Pool.filterIt(it notin bridge.nodev1.peerPool.connectedNodes)

  debug "connecting to v1", candidates=candidates.len(), target=target

  # Now attempt connection to random peers from candidate list until we reach target
  let maxAttempts = min(target, candidates.len())
  
  trace "Attempting to connect to random peers from pool", target=maxAttempts
  for i in 1..maxAttempts:
    let
      randIndex = rand(bridge.rng[], candidates.len() - 1)
      randPeer = candidates[randIndex]
    
    debug "Attempting to connect to random peer", randPeer
    asyncSpawn bridge.nodev1.peerPool.connectToNode(randPeer)

    candidates.delete(randIndex, randIndex)
    if candidates.len() == 0:
      # Stop when we've exhausted all candidates
      break;

proc maintenanceLoop*(bridge: WakuBridge) {.async.} =
  while bridge.started:
    trace "running maintenance"
    
    let
      v1Connections = bridge.nodev1.peerPool.connectedNodes.len()
      v2Connections = bridge.nodev2.switch.peerStore[AddressBook].len()
    
    info "Bridge connectivity",
      v1Peers=v1Connections,
      v2Peers=v2Connections

    # Replenish v1 connections if necessary

    if v1Connections < bridge.targetV1Peers:
      debug "Attempting to replenish v1 connections",
        current=v1Connections,
        target=bridge.targetV1Peers

      bridge.connectToV1(bridge.targetV1Peers - v1Connections)
    
    # TODO: we could do similar maintenance for v2 connections here
    
    await sleepAsync(MaintenancePeriod)

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
          nameResolver: NameResolver = nil,
          # Bridge configuration
          nodev2PubsubTopic: wakunode2.Topic,
          v1Pool: seq[Node] = @[],
          targetV1Peers = 0): T
  {.raises: [Defect,IOError, TLSStreamProtocolError, LPError].} =

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
    nodev2 = WakuNode.new(nodev2Key,
                          nodev2BindIp, nodev2BindPort,
                          nodev2ExtIp, nodev2ExtPort,
                          nameResolver = nameResolver)
  
  return WakuBridge(nodev1: nodev1,
                    nodev2: nodev2,
                    nodev2PubsubTopic: nodev2PubsubTopic,
                    rng: rng,
                    v1Pool: v1Pool,
                    targetV1Peers: targetV1Peers)

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
  proc handleEnvReceived(envelope: waku_protocol.Envelope) {.gcsafe, raises: [Defect].} =
    trace "Bridging envelope from V1 to V2", envelope=envelope
    asyncSpawn bridge.toWakuV2(envelope)

  bridge.nodev1.registerEnvReceivedHandler(handleEnvReceived)

  # Handle messages on Waku v2 and bridge to Waku v1
  proc relayHandler(pubsubTopic: string, data: seq[byte]) {.async, gcsafe.} =
    let msg = WakuMessage.init(data)
    if msg.isOk() and msg.get().isBridgeable():
      try:
        trace "Bridging message from V2 to V1", msg=msg.tryGet()
        bridge.toWakuV1(msg.tryGet())
      except ValueError:
        trace "Failed to convert message to Waku v1. Check content-topic format.", msg=msg
        waku_bridge_dropped.inc(labelValues = ["value_error"])
  
  bridge.nodev2.subscribe(bridge.nodev2PubsubTopic, relayHandler)

  bridge.started = true
  asyncSpawn bridge.maintenanceLoop()

proc stop*(bridge: WakuBridge) {.async.} =
  bridge.started = false
  await bridge.nodev2.stop()

{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  import
    eth/p2p/whispernodes,
    libp2p/nameresolving/dnsresolver,
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

  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport.
  let udpPort = conf.devp2pTcpPort

  # Load address configuration
  let
    (nodev1ExtIp, _, _) = setupNat(conf.nat, ClientIdV1,
                                   Port(conf.devp2pTcpPort + conf.portsShift),
                                   Port(udpPort + conf.portsShift))
    # TODO: EthereumNode should have a better split of binding address and
    # external address. Also, can't have different ports as it stands now.
    nodev1Address = if nodev1ExtIp.isNone():
                      Address(ip: parseIpAddress("0.0.0.0"),
                              tcpPort: Port(conf.devp2pTcpPort + conf.portsShift),
                              udpPort: Port(udpPort + conf.portsShift))
                    else:
                      Address(ip: nodev1ExtIp.get(),
                              tcpPort: Port(conf.devp2pTcpPort + conf.portsShift),
                              udpPort: Port(udpPort + conf.portsShift))
    (nodev2ExtIp, nodev2ExtPort, _) = setupNat(conf.nat, clientId,
                                               Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                                               Port(uint16(udpPort) + conf.portsShift))
  
  # Topic interest and bloom
  var topicInterest: Option[seq[waku_protocol.Topic]]
  var bloom: Option[Bloom]
  
  if conf.wakuV1TopicInterest:
    var topics: seq[waku_protocol.Topic]
    topicInterest = some(topics)
  else:
    bloom = some(fullBloom())

  # DNS resolution
  var dnsReslvr: DnsResolver
  if conf.dnsAddrs:
    # Support for DNS multiaddrs
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsAddrsNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53
    
    dnsReslvr = DnsResolver.new(nameServers)
  
  # Initialise bridge with a candidate pool of v1 nodes to connect to
  var v1PoolStrs: seq[string]
  
  if conf.staticnodesV1.len > 0: v1PoolStrs = conf.staticnodesV1
  elif conf.fleetV1 == prod: v1PoolStrs = @WhisperNodes
  elif conf.fleetV1 == staging: v1PoolStrs = @WhisperNodesStaging
  elif conf.fleetV1 == test: v1PoolStrs = @WhisperNodesTest

  let
    v1Pool = v1PoolStrs.mapIt(newNode(ENode.fromString(it).expect("correct node addrs")))
    bridge = WakuBridge.new(nodev1Key = conf.nodekeyV1,
                            nodev1Address = nodev1Address,
                            powRequirement = conf.wakuV1Pow,
                            rng = rng,
                            topicInterest = topicInterest,
                            bloom = bloom,
                            nodev2Key = conf.nodekeyV2,
                            nodev2BindIp = conf.listenAddress, nodev2BindPort = Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                            nodev2ExtIp = nodev2ExtIp, nodev2ExtPort = nodev2ExtPort,
                            nameResolver = dnsReslvr,
                            nodev2PubsubTopic = conf.bridgePubsubTopic,
                            v1Pool = v1Pool,
                            targetV1Peers = min(v1Pool.len(), TargetV1Peers))
  
  waitFor bridge.start()

  # Now load rest of config

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
