{.push raises: [].}

import
  std/[sequtils, strformat],
  results,
  chronicles,
  chronos,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/protocols/connectivity/relay/client,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/ping,
  libp2p/services/autorelayservice,
  libp2p/services/hpservice,
  libp2p/peerid,
  libp2p/wire,
  eth/p2p/discoveryv5/enr,
  eth/p2p/discoveryv5/node as discv5_node,
  eth/net/utils,
  presto,
  metrics,
  metrics/chronos_httpserver,
  brokers/broker_context,
  logos_delivery/api/types,
  logos_delivery/api/kernel_api,
  logos_delivery/waku/[
    waku_core,
    waku_node,
    waku_archive,
    rln,
    waku_store,
    waku_filter_v2,
    waku_relay/protocol,
    waku_enr/sharding,
    waku_enr/multiaddr,
    common/logging,
    node/peer_manager,
    node/health_monitor,
    node/enr_addresses,
    net/net_config,
    node/waku_metrics,
    node/subscription_manager,
    node/waku_node/mix_rln,
    discovery/waku_dnsdisc,
    discovery/waku_discv5,
    discovery/discv5_peer_discovery,
    discovery/external_service_discovery,
    discovery/self_advertisement,
    discovery/autonat_service,
    requests/health_requests,
    requests/node_state_requests,
    factory/node_factory,
    factory/internal_config,
    factory/app_callbacks,
    persistency/persistency,
    factory/validator_signed,
    waku_lightpush/client,
    waku_lightpush_legacy/client,
    waku_store/client,
  ],
  ./factory/waku_conf,
  ./factory/waku_state_info

# Surfaces the Kernel API interface to consumers of the Waku layer.
# `MessageSeenEvent` now lives in `events/kernel_events` (surfaced by the concentrator).
export kernel_api, waku_node

logScope:
  topics = "wakunode waku"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

proc setupSwitchServices*(
    node: Kernel, conf: WakuConf, circuitRelay: Relay, rng: crypto.Rng
) =
  proc onReservation(addresses: seq[MultiAddress]) {.gcsafe, raises: [].} =
    ## This callback only logs the change. When a reservation drops, libp2p
    ## keeps peerInfo unchanged and the route stays until the next update.
    info "circuit relay reservation change", addrs = $addresses

  let autonatService = getAutonatService(rng)
  let newService =
    if conf.circuitRelayClient:
      ## The node assumes it is behind NAT.
      ## It requests circuit-relay reservations to stay reachable.
      const MaxNumRelayServers = 2
      let autoRelayService = AutoRelayService.new(
        MaxNumRelayServers, RelayClient(circuitRelay), onReservation, rng
      )
      Service(HPService.new(autonatService, autoRelayService))
    else:
      Service(autonatService)

  node.switch.services.add(newService)

  # libp2p runs Service.setup only at build time.
  # This service attaches after build, so run its setup here.
  try:
    newService.setup(node.switch)
  except ServiceSetupError as e:
    error "failed to set up libp2p switch service", error = e.msg

## Initialisation

proc newCircuitRelay(isRelayClient: bool): Relay =
  # TODO: Does it mean it's a circuit-relay server when it's false?
  if isRelayClient:
    return RelayClient.new()
  return Relay.new()

proc setupAppCallbacks(
    node: Kernel,
    conf: WakuConf,
    appCallbacks: AppCallbacks,
    healthMonitor: NodeHealthMonitor,
): Result[void, string] =
  if appCallbacks.isNil():
    info "No external callbacks to be set"
    return ok()

  if not appCallbacks.relayHandler.isNil():
    if node.protocols.relay.isNil():
      return err("Cannot configure relayHandler callback without Relay mounted")

    for shardId in conf.subscribeShards.deduplicate():
      let topic = $RelayShard(clusterId: conf.clusterId, shardId: shardId)
      node.subscribe((kind: PubsubSub, topic: topic), appCallbacks.relayHandler).isOkOr:
        return err(fmt"Could not subscribe {topic}: " & $error)

  if not appCallbacks.topicHealthChangeHandler.isNil():
    if node.protocols.relay.isNil():
      return
        err("Cannot configure topicHealthChangeHandler callback without Relay mounted")
    node.protocols.relay.onTopicHealthChange = appCallbacks.topicHealthChangeHandler

  if not appCallbacks.connectionChangeHandler.isNil():
    if node.peerManager.isNil():
      return
        err("Cannot configure connectionChangeHandler callback with empty peer manager")
    node.peerManager.onConnectionChange = appCallbacks.connectionChangeHandler

  if not appCallbacks.connectionStatusChangeHandler.isNil():
    if healthMonitor.isNil():
      return
        err("Cannot configure connectionStatusChangeHandler with empty health monitor")

    healthMonitor.onConnectionStatusChange = appCallbacks.connectionStatusChangeHandler

  return ok()

proc provideNodeState(kernel: Kernel) =
  ## Node-state getters for loosely-coupled components (discovery backends).
  ## Provided at `new` and again at every `start` (discovery backends read them
  ## while starting); `stop` clears them so a stopped node hands out no state.
  ## reprovideIt: replace-or-insert, idempotent across restarts.
  discard GetNodeSwitch.reprovideIt(kernel.brokerCtx):
    ok(kernel.switch)
  discard GetNodePeerManager.reprovideIt(kernel.brokerCtx):
    ok(kernel.peerManager)
  discard GetNodeEnr.reprovideIt(kernel.brokerCtx):
    ok(kernel.enr)
  discard GetNodeKey.reprovideIt(kernel.brokerCtx):
    ok(kernel.key)
  discard GetNodePeerInfo.reprovideIt(kernel.brokerCtx):
    ok(kernel.switch.peerInfo)
  discard GetDynamicBootstrapNodes.reprovideIt(kernel.brokerCtx):
    ok(kernel.discovery.dynamicBootstrapNodes)

proc clearNodeState(kernel: Kernel) =
  GetNodeSwitch.clearProvider(kernel.brokerCtx)
  GetNodePeerManager.clearProvider(kernel.brokerCtx)
  GetNodeEnr.clearProvider(kernel.brokerCtx)
  GetNodeKey.clearProvider(kernel.brokerCtx)
  GetNodePeerInfo.clearProvider(kernel.brokerCtx)
  GetDynamicBootstrapNodes.clearProvider(kernel.brokerCtx)

proc new*(
    T: type Kernel, wakuConf: WakuConf, appCallbacks: AppCallbacks = nil
): Future[Result[Kernel, string]] {.async.} =
  let rng = crypto.newRng()
  let brokerCtx = globalBrokerContext()

  logging.setupLog(wakuConf.logLevel, wakuConf.logFormat)

  ?wakuConf.validate()
  wakuConf.logConf()

  let relay = newCircuitRelay(wakuConf.circuitRelayClient)

  let node = (await setupNode(wakuConf, rng, relay)).valueOr:
    error "Failed setting up node", error = $error
    return err("Failed setting up node: " & $error)

  let monitor = NodeHealthMonitor.new(node, wakuConf.dnsAddrsNameServers)

  node.setupAppCallbacks(wakuConf, appCallbacks, monitor).isOkOr:
    error "Failed setting up app callbacks", error = error
    return err("Failed setting up app callbacks: " & $error)

  node.conf = wakuConf
  node.key = wakuConf.nodeKey
  node.healthMonitorRef = monitor
  node.appCallbacks = appCallbacks
  var kernel = node

  kernel.setupSwitchServices(wakuConf, relay, rng)

  if wakuConf.discv5Conf.isSome():
    kernel.discovery.discv5Discovery = Discv5PeerDiscovery.create(
      wakuConf.discv5Conf.get(), wakuConf.endpointConf.p2pListenAddress, rng
    )
    node.attachDiscovery(kernel.discovery.discv5Discovery)

  if wakuConf.externalDiscoveryConf.isSome():
    let extConf = wakuConf.externalDiscoveryConf.get()
    kernel.discovery.externalDiscovery = ExternalServiceDiscovery.create(
      extConf.serviceLookupInterval, extConf.randomLookupInterval
    )
    node.attachDiscovery(kernel.discovery.externalDiscovery)

  kernel.provideNodeState()

  ## What a host must set up before `start` (a plugin, bootstrap peers). It is
  ## a pure function of this instance's config and captures nothing else, so
  ## unlike the node-state getters it stays registered across stop/start for
  ## the instance's lifetime: a host may query it while the node is stopped.
  discard GetDiscoveryRequirements.reprovideIt(kernel.brokerCtx):
    let ext = wakuConf.externalDiscoveryConf
    ok(
      DiscoveryRequirements(
        isExternalServiceDiscoveryProvided: ext.isSome(),
        bootstrapNodes:
          if ext.isSome():
            ext.get().bootstrapNodes
          else:
            @[],
      )
    )

  ok(kernel)

proc getRunningNetConfig(kernel: Kernel): Future[Result[NetConfig, string]] {.async.} =
  let conf = kernel.conf
  let (tcpPort, websocketPort, quicPort) = getPorts(
    kernel.switch.peerInfo.listenAddrs
  ).valueOr:
    return err("Could not retrieve ports: " & error)

  if tcpPort.isSome():
    conf.endpointConf.p2pTcpPort = tcpPort.get()

  if websocketPort.isSome() and conf.webSocketConf.isSome():
    conf.webSocketConf.get().port = websocketPort.get()

  if quicPort.isSome() and conf.quicConf.isSome():
    conf.quicConf.get().port = quicPort.get()

  # Rebuild NetConfig from the bound ports already read back into `conf`.
  let netConf = (
    await networkConfiguration(
      conf.clusterId, conf.endpointConf, conf.discv5Conf, conf.webSocketConf,
      conf.quicConf, conf.wakuFlags, conf.dnsAddrsNameServers,
    )
  ).valueOr:
    return err("Could not update NetConfig: " & error)

  return ok(netConf)

proc updateEnr(kernel: Kernel): Future[Result[void, string]] {.async.} =
  let netConf: NetConfig = (await getRunningNetConfig(kernel)).valueOr:
    return err("error calling updateNetConfig: " & $error)
  ## discv5 bumped the seed record it was given, and a peer that cached the
  ## higher number ignores a lower one.
  var seqNum = kernel.enr.seqNum
  if not kernel.discovery.wakuDiscv5.isNil():
    seqNum = max(seqNum, kernel.discovery.wakuDiscv5.protocol.localNode.record.seqNum)

  let record = enrConfiguration(kernel.conf, netConf, seqNum + 1).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, kernel.conf.clusterId):
    return err("cluster-id mismatch configured shards")

  kernel.enr = record
  kernel.updateEnrConfiguredEndpoint(netConf)

  return ok()

proc recordEndpoint(record: enr.Record): Opt[discv5_node.Address] =
  ## The discv5 endpoint the record advertises, if it advertises one.
  let typed = record.toTyped().valueOr:
    return Opt.none(discv5_node.Address)
  if typed.ip.isNone() or typed.udp.isNone():
    return Opt.none(discv5_node.Address)
  return
    Opt.some(discv5_node.Address(ip: ipv4(typed.ip.get()), port: Port(typed.udp.get())))

proc captureLearnedEndpoint(node: Kernel, wakuDiscv5: WakuDiscoveryV5) =
  ## discv5 writes the host it learned into its own record and tells nobody.
  ## Every write that can replace that record reads it first, or the update
  ## is gone before the next reconcile tick can see it. A shard update also
  ## writes the record, so only a moved endpoint counts as learning.
  let live = wakuDiscv5.protocol.localNode.record
  if live == node.enr:
    return
  let liveEndpoint = recordEndpoint(live)
  if liveEndpoint == recordEndpoint(node.enr):
    return
  node.enrLearnedEndpoint = liveEndpoint.map(
    proc(a: discv5_node.Address): DiscoveryEndpoint =
      (ip: a.ip, udp: a.port)
  )

proc refreshEnrAddrs*(
    node: Kernel, key: crypto.PrivateKey, wakuDiscv5: WakuDiscoveryV5
): Result[void, string] =
  ## With discv5, update its live record and copy the result back. A host
  ## discv5 learned from its peers stays the host of the record.
  if wakuDiscv5.isNil():
    return node.enr.updateEnrAddresses(key, node.enrAddresses(), node.enrBaseline())

  node.captureLearnedEndpoint(wakuDiscv5)

  let local = wakuDiscv5.protocol.localNode
  ## Not `local.address`: the line below writes it from the record we are
  ## about to write, so reading it back would feed our own host in as though
  ## peers had voted for it, and no later address could ever replace it.
  ?local.record.updateEnrAddresses(
    key, node.enrAddresses(), node.enrBaseline(), node.enrLearnedEndpoint
  )
  node.enr = local.record
  local.address = recordEndpoint(local.record)
  return ok()

proc reconcileEnrAddrs*(
    node: Kernel, key: crypto.PrivateKey, wakuDiscv5: WakuDiscoveryV5
): Result[bool, string] =
  ## discv5 writes the host it learned into its own record, with the `tcp`
  ## the record had, and tells nobody. Writing again pairs that host with a
  ## `tcp` that fits it. True when it wrote.
  if wakuDiscv5.isNil() or wakuDiscv5.protocol.localNode.record == node.enr:
    return ok(false)
  ?refreshEnrAddrs(node, key, wakuDiscv5)
  return ok(true)

proc logEnrReachability(kernel: Kernel) =
  ## Without an address the record advertises nothing anyone can dial. That is
  ## a normal edge-node state, so it is a notice, and only on a change.
  let reachable = kernel.enr.hasDialableAddress()
  if reachable == kernel.enrReachable:
    return
  kernel.enrReachable = reachable
  if reachable:
    notice "ENR now advertises a reachable host", enr = kernel.enr.toURI()
  else:
    notice "ENR carries no reachable host, so peers cannot dial this node. " &
      "Set --nat, --ext-ip, --dns4-domain-name or --ext-multiaddr to advertise one"

proc enrReconcileLoop(kernel: Kernel): Future[void] {.async.} =
  while true:
    await sleepAsync(kernel.enrReconcileInterval)
    let written = reconcileEnrAddrs(kernel, kernel.key, kernel.discovery.wakuDiscv5).valueOr:
      error "failed to reconcile the ENR with the discv5 record", error = error
      continue
    if written:
      info "ENR reconciled with the discv5 record", enr = kernel.enr.toURI()
      kernel.logEnrReachability()

proc updateWaku(kernel: Kernel): Future[Result[void, string]] {.async.} =
  (await updateEnr(kernel)).isOkOr:
    return err("error calling updateEnr: " & $error)

  if not kernel.discovery.wakuDiscv5.isNil():
    ## Copy the startup ENR into the live discv5 record once. Shard updates
    ## and multiaddr refreshes then update that record in place. The seed
    ## also gave discv5 its own address; the rebuild replaces that too.
    kernel.discovery.wakuDiscv5.protocol.localNode.record = kernel.enr
    kernel.discovery.wakuDiscv5.protocol.localNode.address = Opt.none(discv5_node.Address)
    ## Seeding is not learning: from here on, a record that moved is discv5's.
    kernel.enrLearnedEndpoint = Opt.none(DiscoveryEndpoint)

  ?refreshEnrAddrs(kernel, kernel.key, kernel.discovery.wakuDiscv5)

  return ok()

proc startDnsDiscoveryRetryLoop(kernel: Kernel): Future[void] {.async.} =
  while true:
    await sleepAsync(30.seconds)
    if kernel.conf.dnsDiscoveryConf.isSome():
      let dnsDiscoveryConf = kernel.conf.dnsDiscoveryConf.get()
      kernel.discovery.dynamicBootstrapNodes = (
        await waku_dnsdisc.retrieveDynamicBootstrapNodes(
          dnsDiscoveryConf.enrTreeUrl, kernel.conf.dnsAddrsNameServers
        )
      ).valueOr:
        debug "Retrieving dynamic bootstrap nodes failed", error = error
        continue

    if not kernel.discovery.wakuDiscv5.isNil():
      let dynamicBootstrapEnrs =
        kernel.discovery.dynamicBootstrapNodes.filterIt(it.hasUdpPort()).mapIt(it.enr.get().toUri())
      var discv5BootstrapEnrs: seq[enr.Record]
      # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
      for enrUri in dynamicBootstrapEnrs:
        addBootstrapNode(enrUri, discv5BootstrapEnrs)

      kernel.discovery.wakuDiscv5.updateBootstrapRecords(
        kernel.discovery.wakuDiscv5.protocol.bootstrapRecords & discv5BootstrapEnrs
      )

    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(kernel, kernel.discovery.dynamicBootstrapNodes, "dynamic bootstrap")
    except CatchableError:
      debug "Failed to connect to dynamic bootstrap nodes",
        error = getCurrentExceptionMsg()
    return

proc closePersistency(kernel: Kernel) =
  ## Clear the GetPersistency provider and close the instance (joins any
  ## job worker threads). Idempotent; shared by `stop` and a failed `start`.
  GetPersistency.clearProvider(kernel.brokerCtx)
  if not kernel.persistency.isNil():
    kernel.persistency.close()
    kernel.persistency = nil

proc startKernel*(kernel: Kernel): Future[Result[void, string]] {.async: (raises: []).} =
  if kernel.started:
    debug "start: waku node already started"
    return ok()

  kernel.provideNodeState() # cleared by a previous stop()

  info "Retrieve dynamic bootstrap nodes"
  let conf = kernel.conf

  ## Create this node's Persistency instance and provide it under the node's
  ## BrokerContext first, so any later startup stage can restore persisted
  ## state through it. Inert until the first openJob. The defer below tears
  ## it down again on every one of start's error return paths.
  kernel.persistency = Persistency.new(conf.localStoragePath).valueOr:
    error "Failed to initialize persistency instance", error = $error
    return err("Failed to initialize persistency instance: " & $error)
  discard GetPersistency.reprovideIt(kernel.brokerCtx):
    ok(kernel.persistency)

  var startSucceeded = false
  defer:
    if not startSucceeded:
      await kernel.stopMixRln()
      kernel.closePersistency()

  if conf.dnsDiscoveryConf.isSome():
    let dnsDiscoveryConf = kernel.conf.dnsDiscoveryConf.get()
    let dynamicBootstrapNodesRes =
      try:
        await waku_dnsdisc.retrieveDynamicBootstrapNodes(
          dnsDiscoveryConf.enrTreeUrl, kernel.conf.dnsAddrsNameServers
        )
      except CatchableError as exc:
        Result[seq[RemotePeerInfo], string].err(
          "Retrieving dynamic bootstrap nodes failed: " & exc.msg
        )

    if dynamicBootstrapNodesRes.isErr():
      info "Retrieving dynamic bootstrap nodes failed, starting retry loop",
        error = dynamicBootstrapNodesRes.error
      kernel.discovery.dnsRetryLoopHandle = kernel.startDnsDiscoveryRetryLoop()
    else:
      kernel.discovery.dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

  if not kernel.protocols.wakuMixRln.isNil():
    try:
      (await kernel.startMixRln()).isOkOr:
        return err(error)
    except CancelledError:
      return err("Mix RLN startup cancelled")
  (await startNode(kernel, kernel.conf, kernel.discovery.dynamicBootstrapNodes)).isOkOr:
    return err("error while calling startNode: " & $error)

  let bound = getPorts(kernel.switch.peerInfo.listenAddrs).valueOr:
    return err("failed to read bound ports from switch: " & $error)
  kernel.ports.tcp = bound.tcpPort.get(Port(0)).uint16
  kernel.ports.webSocket = bound.websocketPort.get(Port(0)).uint16
  kernel.ports.quic = bound.quicPort.get(Port(0)).uint16

  ## Discv5
  if not kernel.discovery.discv5Discovery.isNil():
    ## Normally already started by node.start() through the attached
    ## discovery backends; startDiscovery is idempotent and surfaces a
    ## start failure that the node start path only logged.
    (await kernel.discovery.discv5Discovery.startDiscovery()).isOkOr:
      return err("failed to start waku discovery v5: " & error)

    kernel.discovery.wakuDiscv5 = kernel.discovery.discv5Discovery.inner

    let discoveryInfo = (await kernel.discovery.discv5Discovery.backendInfo()).valueOr:
      return err("failed to read discv5 backend info: " & error)
    if discoveryInfo.boundPorts.len > 0:
      kernel.ports.discv5Udp = discoveryInfo.boundPorts[0]
      kernel.conf.discv5Conf.get().udpPort = Port(discoveryInfo.boundPorts[0])

  ## Set the callback before the explicit refresh in updateWaku,
  ## so a commit in between reaches the ENR.
  kernel.onCommittedAddresses = proc() {.gcsafe, raises: [].} =
    refreshEnrAddrs(kernel, kernel.key, kernel.discovery.wakuDiscv5).isOkOr:
      error "failed to refresh ENR multiaddrs", error = $error
      return
    kernel.logEnrReachability()

  ## External service discovery
  if not kernel.discovery.externalDiscovery.isNil():
    ## Configured means required. The plugin is registered at runtime, so a
    ## node can reach start with none installed -- and it would then run
    ## believing it has discovery while having none at all. Same idempotent
    ## re-call as discv5 above, to turn the node start path's logged failure
    ## into a hard one.
    (await kernel.discovery.externalDiscovery.startDiscovery()).isOkOr:
      return err("failed to start external service discovery: " & error)

  ## Update waku data that is set dynamically on node start
  try:
    (await updateWaku(kernel)).isOkOr:
      return err("Error in start: " & $error)
  except CatchableError:
    return err("Caught exception in start: " & getCurrentExceptionMsg())

  kernel.subscriptionManager.subscribeAllAutoshards().isOkOr:
    return err("failed to auto-subscribe autosharding shards: " & $error)

  kernel.logEnrReachability()

  if not kernel.discovery.wakuDiscv5.isNil():
    kernel.enrReconcileLoopHandle = kernel.enrReconcileLoop()

  ## Announce ourselves on the delivery network. After the shard subscriptions,
  ## not before: an advertisement is only useful if the shards it claims are
  ## the ones we are actually on.
  await advertiseSelf(
    kernel.discovery.discoveries,
    kernel.conf,
    kernel.getShardsGetter(kernel.conf.subscribeShards)(),
  )
  await advertiseMix(kernel.discovery.discoveries, kernel.conf)

  ## Health Monitor
  kernel.healthMonitor.startHealthMonitor().isOkOr:
    return err("failed to start health monitor: " & $error)

  ## Setup RequestConnectionStatus provider

  RequestConnectionStatus.setProvider(
    kernel.brokerCtx,
    proc(): Result[RequestConnectionStatus, string] =
      try:
        let healthReport = kernel.healthMonitor.getSyncNodeHealthReport()
        return
          ok(RequestConnectionStatus(connectionStatus: healthReport.connectionStatus))
      except CatchableError:
        err("Failed to read health report: " & getCurrentExceptionMsg()),
  ).isOkOr:
    error "Failed to set RequestConnectionStatus provider", error = error

  ## Setup RequestProtocolHealth provider

  RequestProtocolHealth.setProvider(
    kernel.brokerCtx,
    proc(
        protocol: WakuProtocol
    ): Future[Result[RequestProtocolHealth, string]] {.async.} =
      try:
        let protocolHealthStatus =
          await kernel.healthMonitor.getProtocolHealthInfo(protocol)
        return ok(RequestProtocolHealth(healthStatus: protocolHealthStatus))
      except CatchableError:
        return err("Failed to get protocol health: " & getCurrentExceptionMsg()),
  ).isOkOr:
    error "Failed to set RequestProtocolHealth provider", error = error

  ## Setup RequestHealthReport provider

  RequestHealthReport.setProvider(
    kernel.brokerCtx,
    proc(): Future[Result[RequestHealthReport, string]] {.async.} =
      try:
        let report = await kernel.healthMonitor.getNodeHealthReport()
        return ok(RequestHealthReport(healthReport: report))
      except CatchableError:
        return err("Failed to get health report: " & getCurrentExceptionMsg()),
  ).isOkOr:
    error "Failed to set RequestHealthReport provider", error = error

  if conf.metricsServerConf.isSome():
    try:
      let (server, port) = (
        await waku_metrics.startMetricsServerAndLogging(conf.metricsServerConf.get())
      ).valueOr:
        return err("Starting monitoring and external interfaces failed: " & error)
      kernel.metricsServer = server
      kernel.ports.metrics = port.uint16
      kernel.conf.metricsServerConf.get().httpPort = port
    except CatchableError:
      return err(
        "Caught exception starting monitoring and external interfaces failed: " &
          getCurrentExceptionMsg()
      )
  kernel.healthMonitor.setOverallHealth(HealthStatus.READY)

  startSucceeded = true
  return ok()

proc stopKernel*(kernel: Kernel): Future[Result[void, string]] {.async: (raises: []).} =
  if not kernel.started:
    debug "stop: attempting to stop node that isn't running"

  try:
    kernel.healthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)

    kernel.closePersistency()

    if not kernel.metricsServer.isNil():
      await kernel.metricsServer.stop()

    # discv5 (as attached IPeerDiscovery backend) is stopped by node.stop()

    if not kernel.isNil():
      await kernel.stopMixRln()
      await kernel.stop()

    if not kernel.discovery.dnsRetryLoopHandle.isNil():
      await kernel.discovery.dnsRetryLoopHandle.cancelAndWait()

    if not kernel.enrReconcileLoopHandle.isNil():
      await kernel.enrReconcileLoopHandle.cancelAndWait()

    if not kernel.healthMonitor.isNil():
      await kernel.healthMonitor.stopHealthMonitor()

    ## Clear all providers registered in start() so a later start() can re-set them.
    RequestConnectionStatus.clearProvider(kernel.brokerCtx)
    RequestProtocolHealth.clearProvider(kernel.brokerCtx)
    RequestHealthReport.clearProvider(kernel.brokerCtx)
    ## Node-state getters: provided again by the next start(). Cleared after
    ## node.stop() because discovery backends read them while stopping.
    ## GetDiscoveryRequirements stays (see new): it is config-only.
    kernel.clearNodeState()
  except Exception:
    error "Waku stop failed", error = getCurrentExceptionMsg()
    return err("waku stop failed: " & getCurrentExceptionMsg())

  return ok()

{.pop.}
