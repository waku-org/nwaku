import
  confutils, config, strutils, chronos, json_rpc/rpcserver, metrics,
  chronicles/topics_registry, # TODO: What? Need this for setLoglevel, weird.
  eth/[keys, p2p, async_utils], eth/common/utils, eth/net/nat,
  eth/p2p/[discovery, enode, peer_pool, bootnodes, whispernodes],
  eth/p2p/rlpx_protocols/[whisper_protocol, waku_protocol, waku_bridge],
  # TODO remove me
  ../../vendor/nimbus/nimbus/rpc/[wakusim, key_storage],
  ../../vendor/nim-libp2p/libp2p/standard_setup,
  ../../vendor/nim-libp2p/libp2p/crypto/crypto,
  ../../vendor/nim-libp2p/libp2p/protocols/protocol,
  ../../vendor/nim-libp2p/libp2p/peerinfo,
  rpc/wakurpc

  # TODO: Use
  # protocol/waku_protocol

# TODO: Better aliasing of vendor dirs

# TODO: Something wrong with module imports, "invalid module name" with this
#  ../vendor/nim-libp2p/libp2p/[switch, standard_setup, peerinfo, peer, connection,
#          multiaddress, multicodec, crypto/crypto, protocols/identify, protocols/protocol]

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  # handler defined in parent object
type WakuProto = ref object of LPProtocol
  switch: Switch
  conn: Connection
  connected: bool
  started: bool

const clientId = "Nimbus waku node"

# TODO: We want this to be on top of GossipSub, how does that work?
const WakuCodec = "/vac/waku/2.0.0-alpha0"

let globalListeningAddr = parseIpAddress("0.0.0.0")

proc setBootNodes(nodes: openArray[string]): seq[ENode] =
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # TODO: something more user friendly than an expect
    result.add(ENode.fromString(nodeId).expect("correct node"))

proc connectToNodes(node: EthereumNode, nodes: openArray[string]) =
  for nodeId in nodes:
    # TODO: something more user friendly than an assert
    let whisperENode = ENode.fromString(nodeId).expect("correct node")

    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

# NOTE: Looks almost identical to beacon_chain/eth2_network.nim
proc setupNat(conf: WakuNodeConf): tuple[ip: IpAddress,
                                           tcpPort: Port,
                                           udpPort: Port] =
  # defaults
  result.ip = globalListeningAddr
  result.tcpPort = Port(conf.tcpPort + conf.portsShift)
  result.udpPort = Port(conf.udpPort + conf.portsShift)

  var nat: NatStrategy
  case conf.nat.toLowerAscii():
    of "any":
      nat = NatAny
    of "none":
      nat = NatNone
    of "upnp":
      nat = NatUpnp
    of "pmp":
      nat = NatPmp
    else:
      if conf.nat.startsWith("extip:") and isIpAddress(conf.nat[6..^1]):
        # any required port redirection is assumed to be done by hand
        result.ip = parseIpAddress(conf.nat[6..^1])
        nat = NatNone
      else:
        error "not a valid NAT mechanism, nor a valid IP address", value = conf.nat
        quit(QuitFailure)

  if nat != NatNone:
    let extIP = getExternalIP(nat)
    if extIP.isSome:
      result.ip = extIP.get()
      let extPorts = redirectPorts(tcpPort = result.tcpPort,
                                   udpPort = result.udpPort,
                                   description = clientId)
      if extPorts.isSome:
        (result.tcpPort, result.udpPort) = extPorts.get()

proc newWakuProto(switch: Switch): WakuProto =
  var wakuproto = WakuProto(switch: switch, codec: WakuCodec)

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    let msg = cast[string](await conn.readLp())
    await conn.writeLp("Hello!")
    await conn.close()

  wakuproto.handler = handle
  return wakuproto

proc run(config: WakuNodeConf) =

  info "libp2p support NYI"

  if config.logLevel != LogLevel.NONE:
    setLogLevel(config.logLevel)

  let
    # External TCP and UDP ports
    (ip, tcpPort, udpPort) = setupNat(config)
    address = Address(ip: ip, tcpPort: tcpPort, udpPort: udpPort)

    port = tcpPort
    # Using this for now
    DefaultAddr = "/ip4/127.0.0.1/tcp/55505"
    hostAddress = MultiAddress.init(DefaultAddr)

    # Difference between announced and host address relevant for running behind NAT, however doesn't seem like nim-libp2p supports this. GHI?
    #
    # TODO: Convert config.nodekey eth.key to libp2p.crypto key. Should work with Secp256k1, just need to ensure representation etc is the same. Using random now for spike.
    #nodekey = config.nodekey
    #keys = crypto.KeyPair(nodekey)
    privKey = PrivateKey.random(Secp256k1)
    keys = KeyPair(seckey: privKey, pubkey: privKey.getKey())
    peerInfo = PeerInfo.init(privKey)

  info "Initializing networking (host address and announced same)", address

  peerInfo.addrs.add(Multiaddress.init(DefaultAddr))

  # XXX: It isn't clear that it is a good idea use dial/connect as RPC
  # But let's try it
  # More of a hello world thing, we'd want to mount it on to of gossipsub
  if config.rpc:
    # What is ta? transport address...right.
    let ta = initTAddress(config.rpcAddress,
                          Port(config.rpcPort + config.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    let keys = newKeyStorage()
    # Ok cool no node here
    # TODO: Fix me with node etc
    #setupWakuRPC(node, keys, rpcServer)
    #setupWakuSimRPC(node, rpcServer)
    rpcServer.start()


  # TODO: Here setup a libp2p node
  # Essentially something like this in nbc/eth2_network:
  # proc createEth2Node*(conf: BeaconNodeConf): Future[Eth2Node]
  # TODO: Also see beacon_chain/beaconnode, RPC server etc
  # Also probably start with floodsub for simplicity
  # Slice it up only minimal parts here
  # HERE ATM
  # config.nodekey = KeyPair.random().tryGet()
  # address = set above; ip, tcp and udp port (incl NAT)
  # clientId = "Nimbus waku node"
  #let network = await createLibP2PNode(conf) # doing in-line
  # let rpcServer ...

  # Is it a "Standard" Switch? Assume it is for now
  var switch = newStandardSwitch(some keys.seckey, hostAddress, triggerSelf = true, gossip = true)
  let wakuProto = newWakuProto(switch)
  switch.mount(wakuProto)

  # TODO: Make context async
  #let fut = await switch.start()
  discard switch.start()
  wakuProto.started = true

  let id = peerInfo.peerId.pretty
  info "PeerInfo", id = id, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[0] & "/ipfs/" & id
  info "Listening on", full = listenStr

  # Here directchat uses rwLoop for protocol
  # What if we dial here? How dial?
  # Feels very ghetto, this hookup

  # Once we have a switch and started it, we need to connect the them
  # Then we can dial a peer on a protocol

  # If we start node 2 this should do:
  # let conn = switch.dial(peerInfo, WakuCodec)
  # (testswitch.nim) Conn write hello
  # Aight so we calling here, but where
  # This is why nice to have RPC - how does this look in libp2p?

  # Is this doable with RPC in DevP2P? Probably. How? For quicksim
  # (quicksim.nim) Basically RPC HTTP Client and connect

  # Ok, now what? Quick break. Probably RPC etc? Try to dial, 1:1 style
  # Also not actually using GossipSub so far
  # We want to dial with another node

  # Set-up node
#  var node = newEthereumNode(config.nodekey, address, 1, nil, clientId,
#    addAllCapabilities = false)
#  if not config.bootnodeOnly:
#    node.addCapability Waku # Always enable Waku protocol
#    var topicInterest: Option[seq[waku_protocol.Topic]]
#    var bloom: Option[Bloom]
#    if config.wakuTopicInterest:
#      var topics: seq[waku_protocol.Topic]
#      topicInterest = some(topics)
#    else:
#      bloom = some(fullBloom())
#    let wakuConfig = WakuConfig(powRequirement: config.wakuPow,
#                                bloom: bloom,
#                                isLightNode: config.lightNode,
#                                maxMsgSize: waku_protocol.defaultMaxMsgSize,
#                                topics: topicInterest)
#    node.configureWaku(wakuConfig)
#    if config.whisper or config.whisperBridge:
#      node.addCapability Whisper
#      node.protocolState(Whisper).config.powRequirement = 0.002
#    if config.whisperBridge:
#      node.shareMessageQueue()
#
#  # TODO: Status fleet bootnodes are discv5? That will not work.
#  let bootnodes = if config.bootnodes.len > 0: setBootNodes(config.bootnodes)
#                  elif config.fleet == prod: setBootNodes(StatusBootNodes)
#                  elif config.fleet == staging: setBootNodes(StatusBootNodesStaging)
#                  elif config.fleet == test : setBootNodes(StatusBootNodesTest)
#                  else: @[]
#
#  traceAsyncErrors node.connectToNetwork(bootnodes, not config.noListen,
#    config.discovery)
#
#  if not config.bootnodeOnly:
#    # Optionally direct connect with a set of nodes
#    if config.staticnodes.len > 0: connectToNodes(node, config.staticnodes)
#    elif config.fleet == prod: connectToNodes(node, WhisperNodes)
#    elif config.fleet == staging: connectToNodes(node, WhisperNodesStaging)
#    elif config.fleet == test: connectToNodes(node, WhisperNodesTest)
#
#  if config.rpc:
#    let ta = initTAddress(config.rpcAddress,
#      Port(config.rpcPort + config.portsShift))
#    var rpcServer = newRpcHttpServer([ta])
#    let keys = newKeyStorage()
#    setupWakuRPC(node, keys, rpcServer)
#    setupWakuSimRPC(node, rpcServer)
#    rpcServer.start()
#
#  when defined(insecure):
#    if config.metricsServer:
#      let
#        address = config.metricsServerAddress
#        port = config.metricsServerPort + config.portsShift
#      info "Starting metrics HTTP server", address, port
#      metrics.startHttpServer($address, Port(port))
#
#  if config.logMetrics:
#    proc logMetrics(udata: pointer) {.closure, gcsafe.} =
#      {.gcsafe.}:
#        let
#          connectedPeers = connected_peers.value
#          validEnvelopes = waku_protocol.valid_envelopes.value
#          invalidEnvelopes = waku_protocol.dropped_expired_envelopes.value +
#            waku_protocol.dropped_from_future_envelopes.value +
#            waku_protocol.dropped_low_pow_envelopes.value +
#            waku_protocol.dropped_too_large_envelopes.value +
#            waku_protocol.dropped_bloom_filter_mismatch_envelopes.value +
#            waku_protocol.dropped_topic_mismatch_envelopes.value +
#            waku_protocol.dropped_benign_duplicate_envelopes.value +
#            waku_protocol.dropped_duplicate_envelopes.value
#
#      info "Node metrics", connectedPeers, validEnvelopes, invalidEnvelopes
#      addTimer(Moment.fromNow(2.seconds), logMetrics)
#    addTimer(Moment.fromNow(2.seconds), logMetrics)
#
  runForever()

when isMainModule:
  let conf = WakuNodeConf.load()
  run(conf)
