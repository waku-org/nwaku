import
  std/[strutils, options, tables],
  chronos, confutils, json_rpc/rpcserver, metrics, stew/shims/net as stewNet,
  # TODO: Why do we need eth keys?
  eth/keys,
  # eth/[keys, p2p], eth/net/nat, eth/p2p/[discovery, enode],
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  # NOTE For TopicHandler, solve with exports?
  libp2p/protocols/pubsub/pubsub,
  libp2p/peerinfo,
  rpc/wakurpc,
  standard_setup,
  ../../protocol/v2/[waku_relay, waku_store, waku_filter], ../common,
  ./waku_types, ./config, ./standard_setup, ./rpc/wakurpc

# NOTE Any difference here in Waku vs Eth2?
# E.g. Devp2p/Libp2p support, etc.
#func asLibp2pKey*(key: keys.PublicKey): PublicKey =
#  PublicKey(scheme: Secp256k1, skkey: secp.SkPublicKey(key))

func asEthKey*(key: PrivateKey): keys.PrivateKey =
  keys.PrivateKey(key.skkey)

proc initAddress(T: type MultiAddress, str: string): T =
  let address = MultiAddress.init(str).tryGet()
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(ValueError,
                       "Invalid bootstrap node multi-address")

template tcpEndPoint(address, port): auto =
  MultiAddress.init(address, tcpProtocol, port)

proc dialPeer(n: WakuNode, address: string) {.async.} =
  info "dialPeer", address = address
  # XXX: This turns ipfs into p2p, not quite sure why
  let multiAddr = MultiAddress.initAddress(address)
  info "multiAddr", ma = multiAddr
  let parts = address.split("/")
  let remotePeer = PeerInfo.init(parts[^1], [multiAddr])

  info "Dialing peer", multiAddr
  # NOTE This is dialing on WakuRelay protocol specifically
  # TODO Keep track of conn and connected state somewhere (WakuRelay?)
  #p.conn = await p.switch.dial(remotePeer, WakuRelayCodec)
  #p.connected = true
  discard n.switch.dial(remotePeer, WakuRelayCodec)
  info "Post switch dial"

proc connectToNodes(n: WakuNode, nodes: openArray[string]) =
  for nodeId in nodes:
    info "connectToNodes", node = nodeId
    # XXX: This seems...brittle
    discard dialPeer(n, nodeId)
    # Waku 1
    #    let whisperENode = ENode.fromString(nodeId).expect("correct node")
    #    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

proc startRpc(node: WakuNode, rpcIp: ValidIpAddress, rpcPort: Port) =
  let
    ta = initTAddress(rpcIp, rpcPort)
    rpcServer = newRpcHttpServer([ta])
  setupWakuRPC(node, rpcServer)
  rpcServer.start()
  info "RPC Server started", ta

proc startMetricsServer(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    metrics.startHttpServer($serverIp, serverPort)

proc startMetricsLog() =
  proc logMetrics(udata: pointer) {.closure, gcsafe.} =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.
      let
        totalMessages = total_messages.value

    info "Node metrics", totalMessages
    discard setTimer(Moment.fromNow(2.seconds), logMetrics)
  discard setTimer(Moment.fromNow(2.seconds), logMetrics)

when isMainModule:
  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.libp2pAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  waitFor node.start()

  if conf.staticnodes.len > 0:
    connectToNodes(node, conf.staticnodes)

  if conf.rpc:
    startRpc(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift))

  if conf.logMetrics:
    startMetricsLog()

  when defined(insecure):
    if conf.metricsServer:
      startMetricsServer(conf.metricsServerAddress,
        Port(conf.metricsServerPort + conf.portsShift))

  runForever()
