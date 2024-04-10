when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  chronicles/topics_registry,
  chronos,
  confutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  metrics,
  metrics/chronos_httpserver,
  stew/results


import
  ../../waku/discovery/waku_discv5,
  ../../waku/factory/networks_config,
  ../../waku/waku_enr,
  ../../waku/waku_node,
  ../../waku/waku_relay,
  ../../waku/waku_rln_relay,
  ../../waku/factory/builder,
  ./networkspammer_config


logScope:
  topics = "networkspammer"

const git_version* {.strdefine.} = "n/a"


proc startMetricsServer*(serverIp: IpAddress, serverPort: Port): Result[void, string] =
  info "Starting metrics HTTP server", serverIp, serverPort

  try:
    startMetricsHttpServer($serverIp, serverPort)
  except Exception as e:
    error(
      "Failed to start metrics HTTP server",
      serverIp = serverIp,
      serverPort = serverPort,
      msg = e.msg,
    )

  info "Metrics HTTP server started", serverIp, serverPort
  ok()


proc initAndStartApp(
    conf: NetworkSpammerConfig
): Result[(WakuNode, WakuDiscoveryV5), string] =
  let bindIp =
    try:
      parseIpAddress("0.0.0.0")
    except CatchableError:
      return err("could not start node: " & getCurrentExceptionMsg())

  let extIp =
    try:
      parseIpAddress("127.0.0.1")
    except CatchableError:
      return err("could not start node: " & getCurrentExceptionMsg())

  let
    # some hardcoded parameters
    rng = keys.newRng()
    key = crypto.PrivateKey.random(Secp256k1, rng[])[]
    nodeTcpPort = Port(60000)
    nodeUdpPort = Port(9000)
    flags = CapabilitiesBitfield.init(
      lightpush = false, filter = false, store = false, relay = true
    )

  var builder = EnrBuilder.init(key)

  builder.withIpAddressAndPorts(
    ipAddr = some(extIp), tcpPort = some(nodeTcpPort), udpPort = some(nodeUdpPort)
  )
  builder.withWakuCapabilities(flags)
  let addShardedTopics = builder.withShardedTopics(conf.pubsubTopics)
  if addShardedTopics.isErr():
    error "failed to add sharded topics to ENR", error = addShardedTopics.error
    return err($addShardedTopics.error)

  let recordRes = builder.build()
  let record =
    if recordRes.isErr():
      return err("cannot build record: " & $recordRes.error)
    else:
      recordRes.get()

  var nodeBuilder = WakuNodeBuilder.init()

  nodeBuilder.withNodeKey(key)
  nodeBuilder.withRecord(record)
  nodeBUilder.withSwitchConfiguration(maxConnections = some(150))
  nodeBuilder.withPeerManagerConfig(maxRelayPeers = some(20), shardAware = true)
  let res = nodeBuilder.withNetworkConfigurationDetails(bindIp, nodeTcpPort)
  if res.isErr():
    return err("node building error" & $res.error)

  let nodeRes = nodeBuilder.build()
  let node =
    if nodeRes.isErr():
      return err("node building error" & $res.error)
    else:
      nodeRes.get()

  var discv5BootstrapEnrs: seq[Record]
  # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
  for enrUri in conf.bootstrapNodes:
    addBootstrapNode(enrUri, discv5BootstrapEnrs)

  # discv5
  let discv5Conf = WakuDiscoveryV5Config(
    discv5Config: none(DiscoveryConfig),
    address: bindIp,
    port: nodeUdpPort,
    privateKey: keys.PrivateKey(key.skkey),
    bootstrapRecords: discv5BootstrapEnrs,
    autoupdateRecord: false,
  )

  let wakuDiscv5 = WakuDiscoveryV5.new(node.rng, discv5Conf, some(record))

  try:
    wakuDiscv5.protocol.open()
  except CatchableError:
    return err("could not start node: " & getCurrentExceptionMsg())

  ok((node, wakuDiscv5))

when isMainModule:
  # known issue: confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
  {.pop.}
  let confRes = NetworkSpammerConfig.loadConfig()
  if confRes.isErr():
    error "could not load cli variables", err = confRes.error
    quit(1)

  var conf = confRes.get()
  info "cli flags", conf = conf

  if conf.clusterId == 1:
    let twnClusterConf = ClusterConf.TheWakuNetworkConf()

    conf.bootstrapNodes = twnClusterConf.discv5BootstrapNodes
    conf.pubsubTopics = twnClusterConf.pubsubTopics
    conf.rlnRelayDynamic = twnClusterConf.rlnRelayDynamic
    conf.rlnRelayEthContractAddress = twnClusterConf.rlnRelayEthContractAddress
    conf.rlnEpochSizeSec = twnClusterConf.rlnEpochSizeSec
    conf.rlnRelayUserMessageLimit = twnClusterConf.rlnRelayUserMessageLimit

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  # start metrics server
  if conf.metricsServer:
    let res =
      startMetricsServer(conf.metricsServerAddress, Port(conf.metricsServerPort))
    if res.isErr():
      error "could not start metrics server", err = res.error
      quit(1)

  let (node, _) = initAndStartApp(conf).valueOr:
    error "failed to setup the node", err = error
    quit(1)

  waitFor node.mountRelay()
  waitFor node.mountLibp2pPing()

  if conf.rlnRelayEthContractAddress != "":
    let rlnConf = WakuRlnConfig(
      rlnRelayDynamic: conf.rlnRelayDynamic,
      rlnRelayCredIndex: some(uint(0)),
      rlnRelayEthContractAddress: conf.rlnRelayEthContractAddress,
      rlnRelayEthClientAddress: string(conf.rlnRelayethClientAddress),
      rlnRelayCredPath: "",
      rlnRelayCredPassword: "",
      rlnRelayTreePath: conf.rlnRelayTreePath,
      rlnEpochSizeSec: conf.rlnEpochSizeSec,
    )

    try:
      waitFor node.mountRlnRelay(rlnConf)
    except CatchableError:
      error "failed to setup RLN", err = getCurrentExceptionMsg()
      quit 1

  node.mountMetadata(conf.clusterId).isOkOr:
    error "failed to mount waku metadata protocol: ", err = error
    quit 1

  for pubsubTopic in conf.pubsubTopics:
    # Subscribe the node to the default pubsubtopic, to count messages
    node.subscribe((kind: PubsubSub, topic: pubsubTopic), none(WakuRelayHandler))


  runForever()
  