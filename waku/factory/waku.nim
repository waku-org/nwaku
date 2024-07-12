{.push raises: [].}

import
  std/[options, sequtils],
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

  wakuDiscv5*: WakuDiscoveryV5
  dynamicBootstrapNodes: seq[RemotePeerInfo]

  node*: WakuNode

  restServer*: WakuRestServerRef
  metricsServer*: MetricsHttpServerRef

proc key*(waku: Waku): crypto.PrivateKey =
  waku.node.key

proc logConfig(conf: WakuNodeConf) =
  info "Configuration: Enabled protocols",
    relay = conf.relay,
    rlnRelay = conf.rlnRelay,
    store = conf.store,
    filter = conf.filter,
    lightpush = conf.lightpush,
    peerExchange = conf.peerExchange

  info "Configuration. Network", cluster = conf.clusterId, maxPeers = conf.maxRelayPeers

  for shard in conf.pubsubTopics:
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

## Initialisation

proc init*(T: type Waku, srcConf: WakuNodeConf): Result[Waku, string] =
  let rng = crypto.newRng()

  logging.setupLog(srcConf.logLevel, srcConf.logFormat)

  # Why can't I replace this block with a concise `.valueOr`?
  let finalConf = block:
    let res = applyPresetConfiguration(srcConf)
    if res.isErr():
      error "Failed to complete the config", error = res.error
      return err("Failed to complete the config:" & $res.error)
    res.get()

  logConfig(finalConf)

  info "Running nwaku node", version = git_version

  debug "Retrieve dynamic bootstrap nodes"
  let dynamicBootstrapNodesRes = waku_dnsdisc.retrieveDynamicBootstrapNodes(
    finalConf.dnsDiscovery, finalConf.dnsDiscoveryUrl, finalConf.dnsDiscoveryNameServers
  )
  if dynamicBootstrapNodesRes.isErr():
    error "Retrieving dynamic bootstrap nodes failed",
      error = dynamicBootstrapNodesRes.error
    return err(
      "Retrieving dynamic bootstrap nodes failed: " & dynamicBootstrapNodesRes.error
    )

  let nodeRes = setupNode(finalConf, some(rng))
  if nodeRes.isErr():
    error "Failed setting up node", error = nodeRes.error
    return err("Failed setting up node: " & nodeRes.error)

  var waku = Waku(
    version: git_version,
    conf: finalConf,
    rng: rng,
    node: nodeRes.get(),
    dynamicBootstrapNodes: dynamicBootstrapNodesRes.get(),
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
      waku.node.enr,
      waku.node.peerManager,
      waku.node.topicSubscriptionQueue,
      waku.conf,
      waku.dynamicBootstrapNodes,
      waku.rng,
      waku[].key(),
    )

    (await waku.wakuDiscV5.start()).isOkOr:
      return err("failed to start waku discovery v5: " & $error)

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
