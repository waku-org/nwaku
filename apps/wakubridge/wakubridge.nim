when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables, hashes, sequtils],
  stew/byteutils,
  stew/shims/net as stewNet, json_rpc/rpcserver,
  chronicles,
  chronos,
  chronos/streams/tlsstream,
  metrics,
  metrics/chronos_httpserver,
  libp2p/errors,
  libp2p/peerstore,
  eth/[keys, p2p],
  eth/common/utils,
  eth/p2p/[enode, peer_pool],
  eth/p2p/discoveryv5/random2
import
  # Waku v1 imports
  ../../waku/v1/protocol/waku_protocol,
  # Waku v2 imports
  libp2p/crypto/crypto,
  libp2p/nameresolving/nameresolver,
  ../../waku/v2/waku_enr,
  ../../waku/v2/waku_core,
  ../../waku/v2/waku_store,
  ../../waku/v2/waku_filter,
  ../../waku/v2/node/message_cache,
  ../../waku/v2/waku_node,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/node/jsonrpc/debug/handlers as debug_api,
  ../../waku/v2/node/jsonrpc/filter/handlers as filter_api,
  ../../waku/v2/node/jsonrpc/relay/handlers as relay_api,
  ../../waku/v2/node/jsonrpc/store/handlers as store_api,
  ./message_compat,
  ./config

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
  MaintenancePeriod = 1.minutes
  TargetV1Peers = 4  # Target number of v1 connections to maintain. Could be made configurable in future.

#########
# Types #
#########

type
  WakuBridge* = ref object of RootObj
    nodev1*: EthereumNode
    nodev2*: WakuNode
    nodev2PubsubTopic: waku_core.PubsubTopic # Pubsub topic to bridge to/from
    seen: seq[hashes.Hash] # FIFO queue of seen WakuMessages. Used for deduplication.
    rng: ref HmacDrbgContext
    v1Pool: seq[Node] # Pool of v1 nodes for possible connections
    targetV1Peers: int # Target number of v1 peers to maintain
    started: bool # Indicates that bridge is running

###################
# Helper funtions #
###################

# Deduplication

proc containsOrAdd(sequence: var seq[hashes.Hash], hash: hashes.Hash): bool =
  if sequence.contains(hash):
    return true

  if sequence.len >= DeduplQSize:
    trace "Deduplication queue full. Removing oldest item."
    sequence.delete 0, 0  # Remove first item in queue

  sequence.add(hash)

  return false

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

    debug "Attempting to connect to random peer", randPeer= $randPeer
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
          rng: ref HmacDrbgContext,
          topicInterest = none(seq[waku_protocol.Topic]),
          bloom = some(fullBloom()),
          # NodeV2 initialisation
          nodev2Key: crypto.PrivateKey,
          nodev2BindIp: ValidIpAddress, nodev2BindPort: Port,
          nodev2ExtIp = none[ValidIpAddress](), nodev2ExtPort = none[Port](),
          nameResolver: NameResolver = nil,
          # Bridge configuration
          nodev2PubsubTopic: waku_core.PubsubTopic,
          v1Pool: seq[Node] = @[],
          targetV1Peers = 0): T
  {.raises: [Defect,IOError, TLSStreamProtocolError, LPError].} =

  # Setup Waku v1 node
  var
    nodev1 = newEthereumNode(keys = nodev1Key, address = nodev1Address,
                             networkId = NetworkId(1), clientId = ClientIdV1,
                             addAllCapabilities = false, bindUdpPort = nodev1Address.udpPort, bindTcpPort = nodev1Address.tcpPort, rng = rng)

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

  var builder = EnrBuilder.init(nodev2Key)
  builder.withIpAddressAndPorts(nodev2ExtIp, nodev2ExtPort, none(Port))
  let record = builder.build().tryGet()

  # Setup Waku v2 node
  let nodev2 = block:
      var builder = WakuNodeBuilder.init()
      builder.withNodeKey(nodev2Key)
      builder.withRecord(record)
      builder.withNetworkConfigurationDetails(nodev2BindIp, nodev2BindPort, nodev2ExtIp, nodev2ExtPort).tryGet()
      builder.withSwitchConfiguration(nameResolver=nameResolver)
      builder.build().tryGet()

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
  let connectedFut = bridge.nodev1.connectToNetwork(
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
  await bridge.nodev2.mountRelay()
  bridge.nodev2.wakuRelay.triggerSelf = false

  # Bridging
  # Handle messages on Waku v1 and bridge to Waku v2
  proc handleEnvReceived(envelope: waku_protocol.Envelope) {.gcsafe, raises: [Defect].} =
    trace "Bridging envelope from V1 to V2", envelope=envelope
    asyncSpawn bridge.toWakuV2(envelope)

  bridge.nodev1.registerEnvReceivedHandler(handleEnvReceived)

  # Handle messages on Waku v2 and bridge to Waku v1
  proc relayHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    if msg.isBridgeable():
      try:
        trace "Bridging message from V2 to V1", msg=msg
        bridge.toWakuV1(msg)
      except ValueError:
        trace "Failed to convert message to Waku v1. Check content-topic format.", msg=msg
        waku_bridge_dropped.inc(labelValues = ["value_error"])

  bridge.nodev2.subscribe(bridge.nodev2PubsubTopic, relayHandler)

  bridge.started = true
  asyncSpawn bridge.maintenanceLoop()

proc stop*(bridge: WakuBridge) {.async.} =
  bridge.started = false
  await bridge.nodev2.stop()


proc setupV2Rpc(node: WakuNode, rpcServer: RpcHttpServer, conf: WakuBridgeConf) =
  installDebugApiHandlers(node, rpcServer)

  # Install enabled API handlers:
  if conf.relay:
    let topicCache = relay_api.MessageCache.init(capacity=30)
    installRelayApiHandlers(node, rpcServer, topicCache)

  if conf.filternode != "":
    let messageCache = filter_api.MessageCache.init(capacity=30)
    installFilterApiHandlers(node, rpcServer, messageCache)

  if conf.storenode != "":
    installStoreApiHandlers(node, rpcServer)


{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  import
    std/os,
    libp2p/nameresolving/dnsresolver
  import
    ../../waku/common/logging,
    ../../waku/common/utils/nat,
    ../../waku/whisper/whispernodes,
    ../../waku/v1/node/rpc/wakusim,
    ../../waku/v1/node/rpc/waku,
    ../../waku/v1/node/rpc/key_storage

  const versionString = "version / git commit hash: " & git_version

  let rng = keys.newRng()

  let confRes = WakuBridgeConf.load(version=versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error=confRes.error
    quit(QuitFailure)

  let conf = confRes.get()

  ## Logging setup

  # Adhere to NO_COLOR initiative: https://no-color.org/
  let color = try: not parseBool(os.getEnv("NO_COLOR", "false"))
              except CatchableError: true

  logging.setupLogLevel(conf.logLevel)
  logging.setupLogFormat(conf.logFormat, color)


  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport.
  let udpPort = conf.devp2pTcpPort

  let natRes = setupNat(conf.nat, ClientIdV1,
                        Port(conf.devp2pTcpPort + conf.portsShift),
                        Port(udpPort + conf.portsShift))
  if natRes.isErr():
    error "failed setupNat", error = natRes.error
    quit(QuitFailure)

  let natRes2 = setupNat(conf.nat, clientId,
                         Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
                         Port(uint16(udpPort) + conf.portsShift))
  if natRes2.isErr():
    error "failed setupNat", error = natRes2.error
    quit(QuitFailure)

  # Load address configuration
  let
    (nodev1ExtIp, _, _) = natRes.get()
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
    (nodev2ExtIp, nodev2ExtPort, _) = natRes2.get()

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
  waitFor mountLibp2pPing(bridge.nodev2)

  if conf.store:
    waitFor mountStore(bridge.nodev2)  # Bridge does not persist messages

  if conf.filter:
    waitFor mountFilter(bridge.nodev2)

  if conf.staticnodesV2.len > 0:
    waitFor connectToNodes(bridge.nodev2, conf.staticnodesV2)

  if conf.storenode != "":
    mountStoreClient(bridge.nodev2)
    let storeNode = parsePeerInfo(conf.storenode)
    if storeNode.isOk():
      bridge.nodev2.peerManager.addServicePeer(storeNode.value, WakuStoreCodec)
    else:
      error "Couldn't parse conf.storenode", error = storeNode.error

  if conf.filternode != "":
    waitFor mountFilterClient(bridge.nodev2)
    let filterNode = parsePeerInfo(conf.filternode)
    if filterNode.isOk():
      bridge.nodev2.peerManager.addServicePeer(filterNode.value, WakuFilterCodec)
    else:
      error "Couldn't parse conf.filternode", error = filterNode.error

  if conf.rpc:
    let ta = initTAddress(conf.rpcAddress,
      Port(conf.rpcPort + conf.portsShift))
    var rpcServer = newRpcHttpServer([ta])

    # Waku v1 RPC
    let keys = newKeyStorage()
    setupWakuRPC(bridge.nodev1, keys, rpcServer, rng)
    setupWakuSimRPC(bridge.nodev1, rpcServer)

    # Waku v2 rpc
    setupV2Rpc(bridge.nodev2, rpcServer, conf)

    rpcServer.start()

  if conf.metricsServer:
    let
      address = conf.metricsServerAddress
      port = conf.metricsServerPort + conf.portsShift
    info "Starting metrics HTTP server", address, port
    startMetricsHttpServer($address, Port(port))

  runForever()
