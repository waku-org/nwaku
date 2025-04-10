{.push raises: [].}

import
  std/[options, sequtils],
  results,
  chronicles,
  chronos,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/protocols/connectivity/relay/client,
  libp2p/wire,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/services/autorelayservice,
  libp2p/services/hpservice,
  libp2p/peerid,
  libp2p/discovery/discoverymngr,
  libp2p/discovery/rendezvousinterface,
  eth/keys,
  eth/p2p/discoveryv5/enr,
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
  ../waku_relay/protocol,
  ../discovery/waku_dnsdisc,
  ../discovery/waku_discv5,
  ../discovery/autonat_service,
  ../waku_enr/sharding,
  ../waku_rln_relay,
  ../waku_store,
  ../waku_filter_v2,
  ../factory/node_factory,
  ../factory/internal_config,
  ../factory/external_config,
  ../factory/app_callbacks,
  ../waku_enr/multiaddr,
  ./waku_conf

logScope:
  topics = "wakunode waku"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

type Waku* = ref object
  version: string
  conf: WakuConf
  rng: ref HmacDrbgContext
  # TODO: remove, part of the conf 
  key: crypto.PrivateKey

  wakuDiscv5*: WakuDiscoveryV5
  dynamicBootstrapNodes: seq[RemotePeerInfo]
  dnsRetryLoopHandle: Future[void]
  discoveryMngr: DiscoveryManager

  node*: WakuNode

  deliveryMonitor: DeliveryMonitor

  restServer*: WakuRestServerRef
  metricsServer*: MetricsHttpServerRef
  appCallbacks*: AppCallbacks

func version*(waku: Waku): string =
  waku.version

proc setupSwitchServices(
    waku: Waku, conf: WakuConf, circuitRelay: Relay, rng: ref HmacDrbgContext
) =
  proc onReservation(addresses: seq[MultiAddress]) {.gcsafe, raises: [].} =
    debug "circuit relay handler new reserve event",
      addrs_before = $(waku.node.announcedAddresses), addrs = $addresses

    waku.node.announcedAddresses.setLen(0) ## remove previous addresses
    waku.node.announcedAddresses.add(addresses)
    debug "waku node announced addresses updated",
      announcedAddresses = waku.node.announcedAddresses

    if not isNil(waku.wakuDiscv5):
      waku.wakuDiscv5.updateAnnouncedMultiAddress(addresses).isOkOr:
        error "failed to update announced multiaddress", error = $error

  let autonatService = getAutonatService(rng)
  if conf.circuitRelayClient:
    ## The node is considered to be behind a NAT or firewall and then it
    ## should struggle to be reachable and establish connections to other nodes
    const MaxNumRelayServers = 2
    let autoRelayService = AutoRelayService.new(
      MaxNumRelayServers, RelayClient(circuitRelay), onReservation, rng
    )
    let holePunchService = HPService.new(autonatService, autoRelayService)
    waku.node.switch.services = @[Service(holePunchService)]
  else:
    waku.node.switch.services = @[Service(autonatService)]

## Initialisation

proc newCircuitRelay(isRelayClient: bool): Relay =
  # TODO: Does it mean it's a circuit-relay server when it's false?
  if isRelayClient:
    return RelayClient.new()
  return Relay.new()

proc setupAppCallbacks(
    node: WakuNode, conf: WakuConf, appCallbacks: AppCallbacks
): Result[void, string] =
  if appCallbacks.isNil():
    info "No external callbacks to be set"
    return ok()

  if not appCallbacks.relayHandler.isNil():
    if node.wakuRelay.isNil():
      return err("Cannot configure relayHandler callback without Relay mounted")

    let autoShards = node.getAutoshards(conf.contentTopics).valueOr:
      return err("Could not get autoshards: " & error)

    let confShards =
      conf.shards.mapIt(RelayShard(clusterId: conf.clusterId, shardId: uint16(it)))
    let shards = confShards & autoShards

    for shard in shards:
      discard node.wakuRelay.subscribe($shard, appCallbacks.relayHandler)

  if not appCallbacks.topicHealthChangeHandler.isNil():
    if node.wakuRelay.isNil():
      return
        err("Cannot configure topicHealthChangeHandler callback without Relay mounted")
    node.wakuRelay.onTopicHealthChange = appCallbacks.topicHealthChangeHandler

  if not appCallbacks.connectionChangeHandler.isNil():
    if node.peerManager.isNil():
      return
        err("Cannot configure connectionChangeHandler callback with empty peer manager")
    node.peerManager.onConnectionChange = appCallbacks.connectionChangeHandler

  return ok()

proc new*(
    T: type Waku, wakuConf: WakuConf, appCallbacks: AppCallbacks = nil
): Result[Waku, string] =
  let rng = crypto.newRng()

  logging.setupLog(wakuConf.logLevel, wakuConf.logFormat)

  ?wakuConf.validate()

  info "Running nwaku node", version = git_version

  var relay = newCircuitRelay(wakuConf.circuitRelayClient)

  let nodeRes = setupNode(wakuConf, rng, relay)
  if nodeRes.isErr():
    error "Failed setting up node", error = nodeRes.error
    return err("Failed setting up node: " & nodeRes.error)

  let node = nodeRes.get()

  node.setupAppCallbacks(wakuConf, appCallbacks).isOkOr:
    error "Failed setting up app callbacks", error = error
    return err("Failed setting up app callbacks: " & $error)

  ## Delivery Monitor
  var deliveryMonitor: DeliveryMonitor
  if wakuConf.p2pReliabilityEnabled:
    if wakuConf.remoteStoreNode.isNone:
      return err("A remoteStoreNode should be set when reliability mode is on")

    let deliveryMonitorRes = DeliveryMonitor.new(
      node.wakuStoreClient, node.wakuRelay, node.wakuLightpushClient,
      node.wakuFilterClient,
    )
    if deliveryMonitorRes.isErr():
      return err("could not create delivery monitor: " & $deliveryMonitorRes.error)
    deliveryMonitor = deliveryMonitorRes.get()

  var waku = Waku(
    version: git_version,
    conf: wakuConf,
    rng: rng,
    key: wakuConf.nodeKey,
    node: node,
    deliveryMonitor: deliveryMonitor,
    appCallbacks: appCallbacks,
  )

  waku.setupSwitchServices(wakuConf, relay, rng)

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
    conf.p2pTcpPort = tcpPort.get()

  if websocketPort.isSome() and conf.webSocketConf.isSome:
    var websocketConf = conf.webSocketConf.get()
    websocketConf.port = websocketPort.get()

  # Rebuild NetConfig with bound port values
  let netConf = networkConfiguration(conf, clientId).valueOr:
    return err("Could not update NetConfig: " & error)

  return ok(netConf)

proc updateEnr(waku: ptr Waku): Result[void, string] =
  let netConf: NetConfig = getRunningNetConfig(waku).valueOr:
    return err("error calling updateNetConfig: " & $error)

  let record = enrConfiguration(waku[].conf, netConf).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, waku[].conf.clusterId):
    return err("cluster id mismatch configured shards")

  waku[].node.enr = record

  return ok()

proc updateAddressInENR(waku: ptr Waku): Result[void, string] =
  let addresses: seq[MultiAddress] = waku[].node.announcedAddresses
  let encodedAddrs = multiaddr.encodeMultiaddrs(addresses)

  ## First update the enr info contained in WakuNode
  let keyBytes = waku[].key.getRawBytes().valueOr:
    return err("failed to retrieve raw bytes from waku key: " & $error)

  let parsedPk = keys.PrivateKey.fromHex(keyBytes.toHex()).valueOr:
    return err("failed to parse the private key: " & $error)

  let enrFields = @[toFieldPair(MultiaddrEnrField, encodedAddrs)]
  waku[].node.enr.update(parsedPk, extraFields = enrFields).isOkOr:
    return err("failed to update multiaddress in ENR updateAddressInENR: " & $error)

  debug "Waku node ENR updated successfully with new multiaddress",
    enr = waku[].node.enr.toUri(), record = $(waku[].node.enr)

  ## Now update the ENR infor in discv5
  if not waku[].wakuDiscv5.isNil():
    waku[].wakuDiscv5.protocol.localNode.record = waku[].node.enr
    let enr = waku[].wakuDiscv5.protocol.localNode.record

    debug "Waku discv5 ENR updated successfully with new multiaddress",
      enr = enr.toUri(), record = $(enr)

  return ok()

proc updateWaku(waku: ptr Waku): Result[void, string] =
  let conf = waku[].conf
  if conf.p2pTcpPort == Port(0) or
      (conf.websocketConf.isSome and conf.websocketConf.get.port == Port(0)):
    updateEnr(waku).isOkOr:
      return err("error calling updateEnr: " & $error)

  ?updateAnnouncedAddrWithPrimaryIpAddr(waku[].node)

  ?updateAddressInENR(waku)

  return ok()

proc startDnsDiscoveryRetryLoop(waku: ptr Waku): Future[void] {.async.} =
  while true:
    await sleepAsync(30.seconds)
    if waku.conf.dnsDiscoveryConf.isSome:
      let dnsDiscoveryConf = waku.conf.dnsDiscoveryConf.get()
      let dynamicBootstrapNodesRes = await waku_dnsdisc.retrieveDynamicBootstrapNodes(
        dnsDiscoveryConf.enrTreeUrl, dnsDiscoveryConf.nameServers
      )
      if dynamicBootstrapNodesRes.isErr():
        error "Retrieving dynamic bootstrap nodes failed",
          error = dynamicBootstrapNodesRes.error
        continue

      waku[].dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

    if not waku[].wakuDiscv5.isNil():
      let dynamicBootstrapEnrs = waku[].dynamicBootstrapNodes
        .filterIt(it.hasUdpPort())
        .mapIt(it.enr.get().toUri())
      var discv5BootstrapEnrs: seq[enr.Record]
      # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
      for enrUri in dynamicBootstrapEnrs:
        addBootstrapNode(enrUri, discv5BootstrapEnrs)

      waku[].wakuDiscv5.updateBootstrapRecords(
        waku[].wakuDiscv5.protocol.bootstrapRecords & discv5BootstrapEnrs
      )

    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(
        waku[].node, waku[].dynamicBootstrapNodes, "dynamic bootstrap"
      )
    except CatchableError:
      error "failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg()
    return

proc startWaku*(waku: ptr Waku): Future[Result[void, string]] {.async.} =
  debug "Retrieve dynamic bootstrap nodes"
  let conf = waku[].conf

  if conf.dnsDiscoveryConf.isSome:
    let dnsDiscoveryConf = waku.conf.dnsDiscoveryConf.get()
    let dynamicBootstrapNodesRes = await waku_dnsdisc.retrieveDynamicBootstrapNodes(
      dnsDiscoveryConf.enrTreeUrl, dnsDiscoveryConf.nameServers
    )

    if dynamicBootstrapNodesRes.isErr():
      error "Retrieving dynamic bootstrap nodes failed",
        error = dynamicBootstrapNodesRes.error
      # Start Dns Discovery retry loop
      waku[].dnsRetryLoopHandle = waku.startDnsDiscoveryRetryLoop()
    else:
      waku[].dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

  if conf.discv5Conf.isSome and not conf.discv5Conf.get().discv5Only:
    (await startNode(waku.node, waku.conf, waku.dynamicBootstrapNodes)).isOkOr:
      return err("error while calling startNode: " & $error)

    # Update waku data that is set dynamically on node start
    updateWaku(waku).isOkOr:
      return err("Error in updateApp: " & $error)

  ## Discv5
  if conf.discv5Conf.isSome:
    waku[].wakuDiscV5 = waku_discv5.setupDiscoveryV5(
      waku.node.enr,
      waku.node.peerManager,
      waku.node.topicSubscriptionQueue,
      conf.discv5Conf.get(),
      waku.dynamicBootstrapNodes,
      waku.rng,
      conf.nodeKey,
      conf.p2pListenAddress,
      conf.portsShift,
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

  if not waku.dnsRetryLoopHandle.isNil():
    await waku.dnsRetryLoopHandle.cancelAndWait()
