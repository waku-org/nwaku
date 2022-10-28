{.push raises: [Defect].}

import
  confutils, chronos, json_rpc/rpcserver, 
  metrics, metrics/chronicles_support, metrics/chronos_httpserver,
  stew/shims/net as stewNet,
  eth/[keys, p2p], eth/common/utils,
  eth/p2p/[discovery, enode, peer_pool, bootnodes],
  ../../whisper/[whispernodes, whisper_protocol],
  ../protocol/[waku_protocol, waku_bridge],
  ../../common/utils/nat,
  ./rpc/[waku, wakusim, key_storage], ./waku_helpers, ./config

const clientId = "Nimbus waku node"

proc run(config: WakuNodeConf, rng: ref HmacDrbgContext)
      {.raises: [Defect, ValueError, RpcBindError, CatchableError, Exception]} =
  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport.
  let udpPort = config.tcpPort
  let
    (ipExt, tcpPortExt, _) = setupNat(config.nat, clientId,
      Port(config.tcpPort + config.portsShift),
      Port(udpPort + config.portsShift))
  # TODO: EthereumNode should have a better split of binding address and
  # external address. Also, can't have different ports as it stands now.
    address = if ipExt.isNone():
                Address(ip: parseIpAddress("0.0.0.0"),
                  tcpPort: Port(config.tcpPort + config.portsShift),
                  udpPort: Port(udpPort + config.portsShift))
              else:
                Address(ip: ipExt.get(),
                  tcpPort: Port(config.tcpPort + config.portsShift),
                  udpPort: Port(udpPort + config.portsShift))
    bootnodes = if config.bootnodes.len > 0: setBootNodes(config.bootnodes)
                elif config.fleet == prod: setBootNodes(StatusBootNodes)
                elif config.fleet == staging: setBootNodes(StatusBootNodesStaging)
                elif config.fleet == test : setBootNodes(StatusBootNodesTest)
                else: @[]

  # Set-up node
  var node = newEthereumNode(config.nodekey, address, NetworkId(1), clientId,
    addAllCapabilities = false, bootstrapNodes = bootnodes, bindUdpPort = address.udpPort, bindTcpPort = address.tcpPort, rng = rng)
  if not config.bootnodeOnly:
    node.addCapability Waku # Always enable Waku protocol
    var topicInterest: Option[seq[waku_protocol.Topic]]
    var bloom: Option[Bloom]
    if config.wakuTopicInterest:
      var topics: seq[waku_protocol.Topic]
      topicInterest = some(topics)
    else:
      bloom = some(fullBloom())
    let wakuConfig = WakuConfig(powRequirement: config.wakuPow,
                                bloom: bloom,
                                isLightNode: config.lightNode,
                                maxMsgSize: waku_protocol.defaultMaxMsgSize,
                                topics: topicInterest)
    node.configureWaku(wakuConfig)
    if config.whisper or config.whisperBridge:
      node.addCapability Whisper
      node.protocolState(Whisper).config.powRequirement = 0.002
    if config.whisperBridge:
      node.shareMessageQueue()

  let connectedFut = node.connectToNetwork(not config.noListen,
    config.discovery)
  connectedFut.callback = proc(data: pointer) {.gcsafe.} =
    {.gcsafe.}:
      if connectedFut.failed:
        fatal "connectToNetwork failed", msg = connectedFut.readError.msg
        quit(1)

  if not config.bootnodeOnly:
    # Optionally direct connect with a set of nodes
    if config.staticnodes.len > 0: connectToNodes(node, config.staticnodes)
    elif config.fleet == prod: connectToNodes(node, WhisperNodes)
    elif config.fleet == staging: connectToNodes(node, WhisperNodesStaging)
    elif config.fleet == test: connectToNodes(node, WhisperNodesTest)

  if config.rpc:
    let ta = initTAddress(config.rpcAddress,
      Port(config.rpcPort + config.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    let keys = newKeyStorage()
    setupWakuRPC(node, keys, rpcServer, rng)
    setupWakuSimRPC(node, rpcServer)
    rpcServer.start()


  if config.logAccounting:
    # https://github.com/nim-lang/Nim/issues/17369
    var logPeerAccounting: proc(udata: pointer) {.gcsafe, raises: [Defect].}
    logPeerAccounting = proc(udata: pointer) =
      {.gcsafe.}:
        for peer in node.peerPool.peers:
          let
            sent = peer.state(Waku).accounting.sent
            received = peer.state(Waku).accounting.received
            id = peer.network.toEnode
          info "Peer accounting", id, sent, received
          peer.state(Waku).accounting = Accounting(sent: 0, received: 0)

      discard setTimer(Moment.fromNow(2.seconds), logPeerAccounting)
    discard setTimer(Moment.fromNow(2.seconds), logPeerAccounting)

  if config.metricsServer:
    let
      address = config.metricsServerAddress
      port = config.metricsServerPort + config.portsShift
    info "Starting metrics HTTP server", address, port
    startMetricsHttpServer($address, Port(port))

  if config.logMetrics:
    # https://github.com/nim-lang/Nim/issues/17369
    var logMetrics: proc(udata: pointer) {.gcsafe, raises: [Defect].}
    logMetrics = proc(udata: pointer) =
      {.gcsafe.}:
        let
          connectedPeers = connected_peers
          validEnvelopes = waku_protocol.envelopes_valid
          droppedEnvelopes = waku_protocol.envelopes_dropped

      info "Node metrics", connectedPeers, validEnvelopes, droppedEnvelopes
      discard setTimer(Moment.fromNow(2.seconds), logMetrics)
    discard setTimer(Moment.fromNow(2.seconds), logMetrics)

  runForever()

{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  let
    rng = keys.newRng()
    conf = WakuNodeConf.load()

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  case conf.cmd
  of genNodekey:
    echo PrivateKey.random(rng[])
  of noCommand:
    run(conf, rng)
