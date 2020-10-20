import
  confutils, chronos, json_rpc/rpcserver, metrics,
  chronicles, chronicles/topics_registry,
  stew/shims/net as stewNet,
  eth/[keys, p2p], eth/common/utils,
  eth/p2p/[enode, whispernodes],
  ../protocol/v1/waku_protocol, ./common,
  ./v1/rpc/[waku, wakusim, key_storage], ./v1/waku_helpers,
  ./config

const clientIdV1 = "nim-waku v1 node"

proc startWakuV1(config: WakuNodeConf, rng: ref BrHmacDrbgContext):
    EthereumNode =
  let
    (ipExt, tcpPortExt, udpPortExt) = setupNat(config.nat, clientIdV1,
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
  var node = newEthereumNode(config.nodekey, address, 1, nil, clientIdV1,
    addAllCapabilities = false, rng = rng)
  node.addCapability Waku # Always enable Waku protocol
  # Set up the Waku configuration.
  # This node is being set up as a bridge so it gets configured as a node with
  # a full bloom filter so that it will receive and forward all messages.
  # TODO: What is the PoW setting now?
  let wakuConfig = WakuConfig(powRequirement: 0.002,  bloom: some(fullBloom()),
    isLightNode: false, maxMsgSize: waku_protocol.defaultMaxMsgSize,
    topics: none(seq[waku_protocol.Topic]))
  node.configureWaku(wakuConfig)

  # Optionally direct connect with a set of nodes
  if config.staticnodes.len > 0: connectToNodes(node, config.staticnodes)
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

when isMainModule:
  let
    rng = keys.newRng()
    conf = WakuNodeConf.load()

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  let nodev1 = startWakuV1(conf, rng)

  if conf.rpc:
    let ta = initTAddress(conf.rpcAddress,
      Port(conf.rpcPort + conf.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    let keys = newKeyStorage()
    setupWakuRPC(nodev1, keys, rpcServer, rng)
    setupWakuSimRPC(nodev1, rpcServer)
    rpcServer.start()

  when defined(insecure):
    if conf.metricsServer:
      let
        address = conf.metricsServerAddress
        port = conf.metricsServerPort + conf.portsShift
      info "Starting metrics HTTP server", address, port
      metrics.startHttpServer($address, Port(port))

  runForever()
