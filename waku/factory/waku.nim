{.push raises: [].}

import
  std/options,
  results,
  chronicles,
  chronos,
  libp2p/wire,
  libp2p/multicodec,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/peerid,
  eth/keys,
  presto,
  metrics,
  metrics/chronos_httpserver
import
  ../common/logging,
  ../waku_core,
  ../waku_node,
  ../node/peer_manager,
  ../node/health_monitor,
  ../node/delivery_monitor/delivery_monitor,
  ../waku_api/message_cache,
  ../waku_api/rest/server,
  ../waku_archive,
  ../discovery/waku_dnsdisc,
  ../discovery/waku_discv5,
  ../waku_enr/sharding,
  ../waku_rln_relay,
  ../waku_store,
  ../waku_filter_v2,
  ../factory/networks_config,
  ../factory/node_factory,
  ../factory/internal_config,
  ../factory/external_config

logScope:
  topics = "wakunode waku"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

type Waku* = object
  version: string
  conf: WakuNodeConf
  rng: ref HmacDrbgContext
  key: crypto.PrivateKey

  wakuDiscv5*: WakuDiscoveryV5
  dynamicBootstrapNodes: seq[RemotePeerInfo]

  node*: WakuNode

  deliveryMonitor: DeliveryMonitor

  restServer*: WakuRestServerRef
  metricsServer*: MetricsHttpServerRef

proc logConfig(conf: WakuNodeConf) =
  info "Configuration: Enabled protocols",
    relay = conf.relay,
    rlnRelay = conf.rlnRelay,
    store = conf.store,
    filter = conf.filter,
    lightpush = conf.lightpush,
    peerExchange = conf.peerExchange

  info "Configuration. Network", cluster = conf.clusterId, maxPeers = conf.maxRelayPeers

  for shard in conf.shards:
    info "Configuration. Shards", shard = shard

  for i in conf.discv5BootstrapNodes:
    info "Configuration. Bootstrap nodes", node = i

  if conf.rlnRelay and conf.rlnRelayDynamic:
    info "Configuration. Validation",
      mechanism = "onchain rln",
      contract = conf.rlnRelayEthContractAddress,
      maxMessageSize = conf.maxMessageSize,
      rlnEpochSizeSec = conf.rlnEpochSizeSec,
      rlnRelayUserMessageLimit = conf.rlnRelayUserMessageLimit,
      rlnRelayEthClientAddress = string(conf.rlnRelayEthClientAddress)

func version*(waku: Waku): string =
  waku.version

proc validateShards(conf: WakuNodeConf): Result[void, string] =
  let numShardsInNetwork = getNumShardsInNetwork(conf)

  for shard in conf.shards:
    if shard >= numShardsInNetwork:
      let msg =
        "validateShards invalid shard: " & $shard & " when numShardsInNetwork: " &
        $numShardsInNetwork # fmt doesn't work
      error "validateShards failed", error = msg
      return err(msg)

  return ok()

## Initialisation

proc init*(T: type Waku, confCopy: var WakuNodeConf): Result[Waku, string] =
  let rng = crypto.newRng()

  logging.setupLog(confCopy.logLevel, confCopy.logFormat)

  # TODO: remove after pubsubtopic config gets removed
  var shards = newSeq[uint16]()
  if confCopy.pubsubTopics.len > 0:
    let shardsRes = topicsToRelayShards(confCopy.pubsubTopics)
    if shardsRes.isErr():
      error "failed to parse pubsub topic, please format according to static shard specification",
        error = shardsRes.error
      return err("failed to parse pubsub topic: " & $shardsRes.error)

    let shardsOpt = shardsRes.get()

    if shardsOpt.isSome():
      let relayShards = shardsOpt.get()
      if relayShards.clusterId != confCopy.clusterId:
        error "clusterId of the pubsub topic should match the node's cluster. e.g. --pubsub-topic=/waku/2/rs/22/1 and --cluster-id=22",
          nodeCluster = confCopy.clusterId, pubsubCluster = relayShards.clusterId
        return err(
          "clusterId of the pubsub topic should match the node's cluster. e.g. --pubsub-topic=/waku/2/rs/22/1 and --cluster-id=22"
        )

      for shard in relayShards.shardIds:
        shards.add(shard)
      confCopy.shards = shards

  case confCopy.clusterId

  # cluster-id=1 (aka The Waku Network)
  of 1:
    let twnClusterConf = ClusterConf.TheWakuNetworkConf()

    # Override configuration
    confCopy.maxMessageSize = twnClusterConf.maxMessageSize
    confCopy.clusterId = twnClusterConf.clusterId
    confCopy.rlnRelayEthContractAddress = twnClusterConf.rlnRelayEthContractAddress
    confCopy.rlnRelayChainId = twnClusterConf.rlnRelayChainId
    confCopy.rlnRelayDynamic = twnClusterConf.rlnRelayDynamic
    confCopy.rlnRelayBandwidthThreshold = twnClusterConf.rlnRelayBandwidthThreshold
    confCopy.discv5Discovery = twnClusterConf.discv5Discovery
    confCopy.discv5BootstrapNodes =
      confCopy.discv5BootstrapNodes & twnClusterConf.discv5BootstrapNodes
    confCopy.rlnEpochSizeSec = twnClusterConf.rlnEpochSizeSec
    confCopy.rlnRelayUserMessageLimit = twnClusterConf.rlnRelayUserMessageLimit
    confCopy.numShardsInNetwork = twnClusterConf.numShardsInNetwork

    # Only set rlnRelay to true if relay is configured
    if confCopy.relay:
      confCopy.rlnRelay = twnClusterConf.rlnRelay
  else:
    discard

  info "Running nwaku node", version = git_version
  logConfig(confCopy)

  let validateShardsRes = validateShards(confCopy)
  if validateShardsRes.isErr():
    error "Failed validating shards", error = $validateShardsRes.error
    return err("Failed validating shards: " & $validateShardsRes.error)

  if not confCopy.nodekey.isSome():
    let keyRes = crypto.PrivateKey.random(Secp256k1, rng[])
    if keyRes.isErr():
      error "Failed to generate key", error = $keyRes.error
      return err("Failed to generate key: " & $keyRes.error)
    confCopy.nodekey = some(keyRes.get())

  debug "Retrieve dynamic bootstrap nodes"
  let dynamicBootstrapNodesRes = waku_dnsdisc.retrieveDynamicBootstrapNodes(
    confCopy.dnsDiscovery, confCopy.dnsDiscoveryUrl, confCopy.dnsDiscoveryNameServers
  )
  if dynamicBootstrapNodesRes.isErr():
    error "Retrieving dynamic bootstrap nodes failed",
      error = dynamicBootstrapNodesRes.error
    return err(
      "Retrieving dynamic bootstrap nodes failed: " & dynamicBootstrapNodesRes.error
    )

  let nodeRes = setupNode(confCopy, some(rng))
  if nodeRes.isErr():
    error "Failed setting up node", error = nodeRes.error
    return err("Failed setting up node: " & nodeRes.error)

  let node = nodeRes.get()

  var deliveryMonitor: DeliveryMonitor
  if confCopy.reliabilityEnabled:
    if confCopy.storenode == "":
      return err("A storenode should be set when reliability mode is on")

    let deliveryMonitorRes = DeliveryMonitor.new(
      node.wakuStoreClient, node.wakuRelay, node.wakuLightpushClient,
      node.wakuFilterClient,
    )
    if deliveryMonitorRes.isErr():
      return err("could not create delivery monitor: " & $deliveryMonitorRes.error)
    deliveryMonitor = deliveryMonitorRes.get()

  var waku = Waku(
    version: git_version,
    conf: confCopy,
    rng: rng,
    key: confCopy.nodekey.get(),
    node: node,
    dynamicBootstrapNodes: dynamicBootstrapNodesRes.get(),
    deliveryMonitor: deliveryMonitor,
  )

  ok(waku)

proc getPorts(
    listenAddrs: seq[MultiAddress]
): Result[tuple[tcpPort, websocketPort: Option[Port]], string] =
  var tcpPort, websocketPort = none(Port)

  for a in listenAddrs:
    if a.isWsAddress():
      if websocketPort.isNone():
        let wsAddress = initTAddress(a).valueOr:
          return err("getPorts wsAddr error:" & $error)
        websocketPort = some(wsAddress.port)
    elif tcpPort.isNone():
      let tcpAddress = initTAddress(a).valueOr:
        return err("getPorts tcpAddr error:" & $error)
      tcpPort = some(tcpAddress.port)

  return ok((tcpPort: tcpPort, websocketPort: websocketPort))

proc getRunningNetConfig(waku: ptr Waku): Result[NetConfig, string] =
  var conf = waku[].conf
  let (tcpPort, websocketPort) = getPorts(waku[].node.switch.peerInfo.listenAddrs).valueOr:
    return err("Could not retrieve ports " & error)

  if tcpPort.isSome():
    conf.tcpPort = tcpPort.get()

  if websocketPort.isSome():
    conf.websocketPort = websocketPort.get()

  # Rebuild NetConfig with bound port values
  let netConf = networkConfiguration(conf, clientId).valueOr:
    return err("Could not update NetConfig: " & error)

  return ok(netConf)

proc updateEnr(waku: ptr Waku, netConf: NetConfig): Result[void, string] =
  let record = enrConfiguration(waku[].conf, netConf, waku[].key).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, waku[].conf.clusterId):
    return err("cluster id mismatch configured shards")

  waku[].node.enr = record

  return ok()

proc updateWaku(waku: ptr Waku): Result[void, string] =
  if waku[].conf.tcpPort == Port(0) or waku[].conf.websocketPort == Port(0):
    let netConf = getRunningNetConfig(waku).valueOr:
      return err("error calling updateNetConfig: " & $error)

    updateEnr(waku, netConf).isOkOr:
      return err("error calling updateEnr: " & $error)

    waku[].node.announcedAddresses = netConf.announcedAddresses

    printNodeNetworkInfo(waku[].node)

  return ok()

proc startWaku*(waku: ptr Waku): Future[Result[void, string]] {.async: (raises: []).} =
  if not waku[].conf.discv5Only:
    (await startNode(waku.node, waku.conf, waku.dynamicBootstrapNodes)).isOkOr:
      return err("error while calling startNode: " & $error)

    # Update waku data that is set dynamically on node start
    updateWaku(waku).isOkOr:
      return err("Error in updateApp: " & $error)

  ## Discv5
  if waku[].conf.discv5Discovery or waku[].conf.discv5Only:
    waku[].wakuDiscV5 = waku_discv5.setupDiscoveryV5(
      waku.node.enr, waku.node.peerManager, waku.node.topicSubscriptionQueue, waku.conf,
      waku.dynamicBootstrapNodes, waku.rng, waku.key,
    )

    (await waku.wakuDiscV5.start()).isOkOr:
      return err("failed to start waku discovery v5: " & $error)

  ## Reliability
  if not waku[].deliveryMonitor.isNil():
    waku[].deliveryMonitor.startDeliveryMonitor()

  return ok()

# Waku shutdown

proc stop*(waku: Waku): Future[void] {.async: (raises: [Exception]).} =
  if not waku.restServer.isNil():
    await waku.restServer.stop()

  if not waku.metricsServer.isNil():
    await waku.metricsServer.stop()

  if not waku.wakuDiscv5.isNil():
    await waku.wakuDiscv5.stop()

  if not waku.node.isNil():
    await waku.node.stop()
