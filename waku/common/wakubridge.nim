import
  std/strutils,
  chronos, confutils, chronicles, chronicles/topics_registry, metrics,
  stew/shims/net as stewNet, json_rpc/rpcserver,
  # Waku v1 imports
  eth/[keys, p2p], eth/common/utils,
  eth/p2p/[enode, whispernodes],
  ../v1/protocol/waku_protocol,
  ./utils/nat,
  ../v1/node/rpc/wakusim,
  ../v1/node/waku_helpers,
  # Waku v2 imports
  libp2p/crypto/crypto,
  ../v2/node/wakunode2,
  ../v2/node/rpc/wakurpc,
  # Common cli config
  ./config_bridge

const clientIdV1 = "nim-waku v1 node"

proc startWakuV1(config: WakuNodeConf, rng: ref BrHmacDrbgContext):
    EthereumNode =
  let
    (ipExt, _, _) = setupNat(config.nat, clientIdV1,
      Port(config.devp2pTcpPort + config.portsShift),
      Port(config.udpPort + config.portsShift))
  # TODO: EthereumNode should have a better split of binding address and
  # external address. Also, can't have different ports as it stands now.
    address = if ipExt.isNone():
                Address(ip: parseIpAddress("0.0.0.0"),
                  tcpPort: Port(config.devp2pTcpPort + config.portsShift),
                  udpPort: Port(config.udpPort + config.portsShift))
              else:
                Address(ip: ipExt.get(),
                  tcpPort: Port(config.devp2pTcpPort + config.portsShift),
                  udpPort: Port(config.udpPort + config.portsShift))

  # Set-up node
  var node = newEthereumNode(config.nodekeyv1, address, 1, nil, clientIdV1,
    addAllCapabilities = false, rng = rng)
  node.addCapability Waku # Always enable Waku protocol
  # Set up the Waku configuration.
  # This node is being set up as a bridge so it gets configured as a node with
  # a full bloom filter so that it will receive and forward all messages.
  # TODO: What is the PoW setting now?
  let wakuConfig = WakuConfig(powRequirement: config.wakuPow,
    bloom: some(fullBloom()), isLightNode: false,
    maxMsgSize: waku_protocol.defaultMaxMsgSize,
    topics: none(seq[waku_protocol.Topic]))
  node.configureWaku(wakuConfig)

  # Optionally direct connect with a set of nodes
  if config.staticnodesv1.len > 0: connectToNodes(node, config.staticnodesv1)
  elif config.fleetv1 == prod: connectToNodes(node, WhisperNodes)
  elif config.fleetv1 == staging: connectToNodes(node, WhisperNodesStaging)
  elif config.fleetv1 == test: connectToNodes(node, WhisperNodesTest)

  let connectedFut = node.connectToNetwork(@[],
    true, # Always enable listening
    false # Disable discovery (only discovery v4 is currently supported)
    )
  connectedFut.callback = proc(data: pointer) {.gcsafe.} =
    {.gcsafe.}:
      if connectedFut.failed:
        fatal "connectToNetwork failed", msg = connectedFut.readError.msg
        quit(1)

  return node

proc startWakuV2(config: WakuNodeConf): Future[WakuNode] {.async.} =
  let
    (extIp, extTcpPort, _) = setupNat(config.nat, clientId,
      Port(uint16(config.libp2pTcpPort) + config.portsShift),
      Port(uint16(config.udpPort) + config.portsShift))
    node = WakuNode.init(config.nodeKeyv2, config.listenAddress,
      Port(uint16(config.libp2pTcpPort) + config.portsShift), extIp, extTcpPort)

  await node.start()

  if config.store:
    mountStore(node)

  if config.filter:
    mountFilter(node)

  if config.relay:
    waitFor mountRelay(node, config.topics.split(" "))

  if config.staticnodesv2.len > 0:
    waitFor connectToNodes(node, config.staticnodesv2)

  if config.storenode != "":
    setStorePeer(node, config.storenode)

  if config.filternode != "":
    setFilterPeer(node, config.filternode)

  return node

when isMainModule:
  let
    rng = keys.newRng()
  let conf = WakuNodeConf.load()

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  let
    nodev1 = startWakuV1(conf, rng)
    nodev2 = waitFor startWakuV2(conf)

  if conf.rpc:
    let ta = initTAddress(conf.rpcAddress,
      Port(conf.rpcPort + conf.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    # Waku v1 RPC
    # TODO: Commented out the Waku v1 RPC calls as there is a conflict because
    # of exact same named rpc calls between v1 and v2
    # let keys = newKeyStorage()
    # setupWakuRPC(nodev1, keys, rpcServer, rng)
    setupWakuSimRPC(nodev1, rpcServer)
    # Waku v2 rpc
    setupWakuRPC(nodev2, rpcServer)

    rpcServer.start()

  when defined(insecure):
    if conf.metricsServer:
      let
        address = conf.metricsServerAddress
        port = conf.metricsServerPort + conf.portsShift
      info "Starting metrics HTTP server", address, port
      metrics.startHttpServer($address, Port(port))

  runForever()
