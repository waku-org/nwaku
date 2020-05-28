import
  confutils, config, strutils, chronos, json_rpc/rpcserver, metrics,
  chronicles/topics_registry, # TODO: What? Need this for setLoglevel, weird.
  eth/[keys, p2p], eth/net/nat,
  eth/p2p/[discovery, enode],
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/peerinfo,
  rpc/wakurpc,
  ../../protocol/v2/waku_protocol,
  # TODO: Pull out standard switch from tests
  ../../tests/v2/standard_setup,
  waku_types

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

const clientId = "Nimbus waku node"

let globalListeningAddr = parseIpAddress("0.0.0.0")

proc setBootNodes(nodes: openArray[string]): seq[ENode] =
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # TODO: something more user friendly than an expect
    result.add(ENode.fromString(nodeId).expect("correct node"))

proc initAddress(T: type MultiAddress, str: string): T =
  let address = MultiAddress.init(str)
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(MultiAddressError,
                       "Invalid bootstrap node multi-address")

proc dialPeer(p: WakuProto, address: string) {.async.} =
  info "dialPeer", address = address
  # XXX: This turns ipfs into p2p, not quite sure why
  let multiAddr = MultiAddress.initAddress(address)
  info "multiAddr", ma = multiAddr
  let parts = address.split("/")
  let remotePeer = PeerInfo.init(parts[^1], [multiAddr])

  info "Dialing peer", multiAddr
  p.conn = await p.switch.dial(remotePeer, WakuSubCodec)
  info "Post switch dial"
  # Isn't there just one p instance? Why connected here?
  p.connected = true

# TODO: Connect to multiple static nodes
proc connectToNodes(p: WakuProto, nodes: openArray[string]) =
  let peerInfoStr = nodes[0]
  info "connectToNodes", node = peerInfoStr

  # XXX: Why is ipfs being replaced by p2p here?
  # Whats difference here? We don't have Whisper enodes etc
  discard dialPeer(p, peerInfoStr)
#  for nodeId in nodes:
#    info "connectToNodes nodeid", nodeId
#    # TODO: something more user friendly than an assert
#    let whisperENode = ENode.fromString(nodeId).expect("correct node")
#
#    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

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
  var wakuproto = WakuProto(switch: switch, codec: WakuSubCodec)

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    let msg = cast[string](await conn.readLp(1024))
    await conn.writeLp("Hello!")
    await conn.close()

  wakuproto.handler = handle
  return wakuproto

proc run(config: WakuNodeConf) =

  info "libp2p support WIP"

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
    # NOTE: This is a privatekey
    nodekey = config.nodekey
    seckey = nodekey
    pubkey = seckey.getKey.get()
    keys = KeyPair(seckey: seckey, pubkey: pubkey)

    peerInfo = PeerInfo.init(nodekey)

  info "Initializing networking (host address and announced same)", address

  peerInfo.addrs.add(Multiaddress.init(DefaultAddr))

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
  # NOTE: This should be WakuSub here

  # XXX: Do we want to use this wakuProto? Or Switch?
  # We need access to the WakuSub thing
  # switch.pubsub = wakusub, plus all the peer info etc
  # And it has wakuProto lets use wakuProto maybe, cause it has switch
  var switch = newStandardSwitch(some keys.seckey, hostAddress, triggerSelf = true, gossip = false)
  let wakuProto = newWakuProto(switch)
  switch.mount(wakuProto)

  if config.rpc:
    let ta = initTAddress(config.rpcAddress,
                          Port(config.rpcPort + config.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    setupWakuRPC(wakuProto, rpcServer)
    rpcServer.start()
    info "rpcServer started", ta=ta

  # TODO: Make context async
  #let fut = await switch.start()
  discard switch.start()
  wakuProto.started = true

  let id = peerInfo.peerId.pretty
  info "PeerInfo", id = id, addrs = peerInfo.addrs
  # Try p2p instead
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & id
  #let listenStr = $peerInfo.addrs[0] & "/ipfs/" & id
  # XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

  # XXX: So doing this _after_ other setup
  # Optionally direct connect with a set of nodes
  if config.staticnodes.len > 0: connectToNodes(wakuProto, config.staticnodes)

  if config.logMetrics:
    proc logMetrics(udata: pointer) {.closure, gcsafe.} =
      {.gcsafe.}:
        let
          connectedPeers = connected_peers.value
          totalMessages = total_messages.value
          # NOTE: Just message volume for now, no valid/invalid envelopes
      info "Node metrics", connectedPeers, totalMessages
      # FIXME Warning: Use setTimer/clearTimer instead; addTimer is deprecated [Deprecated]
      addTimer(Moment.fromNow(2.seconds), logMetrics)
    addTimer(Moment.fromNow(2.seconds), logMetrics)

  runForever()

when isMainModule:
  let conf = WakuNodeConf.load()
  run(conf)
