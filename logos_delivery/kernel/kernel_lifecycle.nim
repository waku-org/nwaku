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
  logos_delivery/kernel/[
    subscription_manager,
    topics/content_topic,
    topics/pubsub_topic,
    protocols/message,
    peer_manager/peers,
    net/switch,
    kernel,
    api/filter,
    api/lightpush,
    api/store,
    api/relay,
    api/peer_exchange,
    api/ping,
    archive/common,
    archive/archive,
    archive/retention_policy,
    rln/rln_evm/group_manager,
    rln/rln_evm/conversion_utils,
    rln/rln_evm/rln_evm,
    protocols/store/common,
    protocols/store/protocol,
    protocols/filter/common,
    protocols/filter/protocol,
    protocols/filter/subscriptions,
    protocols/relay/protocol,
    enr/sharding,
    common/logging,
    peer_manager/peer_manager,
    health_monitor/node_health_monitor,
    health_monitor/protocol_health,
    health_monitor/health_status,
    health_monitor/health_report,
    enr/enr_addresses,
    net/net_config,
    metrics_server,
    subscription_manager,
    api/mix,
    discovery/dnsdisc,
    discovery/discv5,
    discovery/discv5_peer_discovery,
    discovery/external_service_discovery,
    discovery/self_advertisement,
    discovery/autonat_service,
    health_monitor/health_requests,
    discovery/node_state_requests,
    factory/internal_config,
    factory/app_callbacks,
    persistency/persistency,
    protocols/lightpush/client,
    protocols/lightpush_legacy/client,
    protocols/store/client,
  ],
  ./factory/conf

# Surfaces the Kernel API interface to consumers of the Waku layer.
# `MessageSeenEvent` now lives in `events/kernel_events` (surfaced by the concentrator).
import
  results,
  std/sequtils,
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/nameresolving/dnsresolver,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/extended_peer_record,
  libp2p_mix/mix_protocol,
  libp2p_mix/spam_protection,
  mix_rln_spam_protection/module_api
import logos_delivery/kernel/api/mix

import
  logos_delivery/kernel/factory/internal_config,
  logos_delivery/kernel/rln/rln_lez/transport,
  logos_delivery/kernel/factory/networks_config,
  logos_delivery/kernel/factory/conf,
  logos_delivery/kernel/factory/builder,
  logos_delivery/kernel/factory/validator_signed,
  logos_delivery/kernel/enr/sharding,
  logos_delivery/kernel/[
    kernel, api/filter, api/lightpush, api/store, api/relay, api/peer_exchange, api/ping
  ],
  logos_delivery/kernel/net/net_config,
  logos_delivery/kernel/net/nat_config,
  logos_delivery/kernel/[topics/pubsub_topic, topics/pubsub_topic, peer_manager/peers],
  logos_delivery/kernel/protocols/codecs,
  logos_delivery/kernel/
    [rln/rln_evm/group_manager, rln/rln_evm/conversion_utils, rln/rln_evm/rln_evm],
  logos_delivery/kernel/rln/rln_plugin,
  logos_delivery/kernel/rln/rln_lez/rln_lez,
  logos_delivery/kernel/discovery/dnsdisc,
  logos_delivery/kernel/archive/retention_policy as policy,
  logos_delivery/kernel/archive/retention_policy/builder as policy_builder,
  logos_delivery/kernel/archive/driver as driver,
  logos_delivery/kernel/archive/driver/builder as driver_builder,
  logos_delivery/kernel/protocols/store/[common],
  logos_delivery/kernel/protocols/store/common as store_common,
  logos_delivery/kernel/protocols/filter/[common],
  logos_delivery/kernel/protocols/peer_exchange/[protocol, common],
  logos_delivery/kernel/discovery/kademlia,
  logos_delivery/kernel/discovery/service_discovery,
  logos_delivery/kernel/[peer_manager/peer_manager],
  logos_delivery/kernel/peer_manager/peer_store/sqlite_peer_storage,
  logos_delivery/kernel/peer_manager/peer_store/migrations as
    peer_store_sqlite_migrations,
  logos_delivery/kernel/protocols/lightpush_legacy/common,
  logos_delivery/kernel/common/rate_limit/setting

export kernel_api, kernel, switch, filter, lightpush, store, relay, peer_exchange, ping

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

## Peer persistence

const PeerPersistenceDbUrl = "peers.db"
proc setupPeerStorage(): Result[Opt[WakuPeerStorage], string] =
  let db = ?SqliteDatabase.new(PeerPersistenceDbUrl)

  ?peer_store_sqlite_migrations.migrate(db)

  let res = WakuPeerStorage.new(db).valueOr:
    return err("failed to init peer store" & error)

  return ok(Opt.some(res))

## Init waku node instance

proc initNode(
    conf: WakuConf,
    netConfig: NetConfig,
    rng: crypto.Rng,
    record: enr.Record,
    peerStore: Opt[WakuPeerStorage],
    relay: Relay,
    dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[],
): Result[Kernel, string] =
  ## Setup a basic Waku v2 node based on a supplied configuration
  ## file. Optionally include persistent peer storage.
  ## No protocols are mounted yet.

  let pStorage =
    if peerStore.isNone():
      nil
    else:
      peerStore.get()

  let (secureKey, secureCert) =
    if conf.webSocketConf.isSome() and conf.webSocketConf.get().secureConf.isSome():
      let wssConf = conf.webSocketConf.get().secureConf.get()
      (Opt.some(wssConf.keyPath), Opt.some(wssConf.certPath))
    else:
      (Opt.none(string), Opt.none(string))

  let nameResolver =
    DnsResolver.new(conf.dnsAddrsNameServers.mapIt(initTAddress(it, Port(53))))

  # Build waku node instance
  var builder = WakuNodeBuilder.init()
  builder.withRng(rng)
  builder.withNodeKey(conf.nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig)
  builder.withPeerStorage(pStorage, capacity = conf.peerStoreCapacity)
  builder.withSwitchConfiguration(
    maxConnections = Opt.some(conf.maxConnections.int),
    secureKey = secureKey,
    secureCert = secureCert,
    nameResolver = nameResolver,
    sendSignedPeerRecord = conf.relayPeerExchange,
      # We send our own signed peer record when peer exchange enabled
    agentString = Opt.some(conf.agentString),
  )
  builder.withColocationLimit(conf.colocationLimit)
  let natConf = natConfig(
    conf.endpointConf.natStrategy,
    conf.endpointConf.natDiscoveryTimeoutMs.int64.milliseconds,
  )
  if conf.endpointConf.extMultiAddrsOnly:
    ## libp2p announces this list as is. Port mapping would target listed
    ## ports that need not be bound, so leave it off.
    if natConf.isSome():
      info "Automatic NAT port mapping stays off under ext-multiaddr-only",
        natStrategy = $conf.endpointConf.natStrategy
  else:
    builder.withNatConfig(natConf)
  builder.withMaxPureLibp2pPeers(conf.maxPureLibp2pPeers)

  if conf.maxRelayPeers.isSome():
    let
      maxRelayPeers = conf.maxRelayPeers.get()
      maxConnections = conf.maxConnections
      # Calculate the ratio as percentages
      relayRatio = (maxRelayPeers.float / maxConnections.float) * 100
      serviceRatio = 100 - relayRatio

    builder.withPeerManagerConfig(
      maxConnections = conf.maxConnections,
      relayServiceRatio = $relayRatio & ":" & $serviceRatio,
      shardAware = conf.relayShardedPeerManagement,
    )
    warn "maxRelayPeers is deprecated, use relayServiceRatio instead",
      relayServiceRatio = $relayRatio & ":" & $serviceRatio
  else:
    builder.withPeerManagerConfig(
      maxConnections = conf.maxConnections,
      relayServiceRatio = conf.relayServiceRatio,
      shardAware = conf.relayShardedPeerManagement,
    )
  builder.withRateLimit(conf.rateLimit)
  builder.withCircuitRelay(relay)

  let node = ?builder.build().mapErr(
    proc(err: string): string =
      "failed to create waku node instance: " & err
  )

  ok(node)

## Mount protocols

proc setupProtocols(
    node: Kernel, conf: WakuConf
): Future[Result[void, string]] {.async.} =
  ## Setup configured protocols on an existing Waku v2 node.
  ## Optionally include persistent message storage.
  ## No protocols are started yet.

  node.mountMetadata(conf.clusterId, conf.subscribeShards).isOkOr:
    return err("failed to mount waku metadata protocol: " & error)

  var onFatalErrorAction = proc(msg: string) {.gcsafe, closure.} =
    ## Action to be taken when an internal error occurs during the node run.
    ## e.g. the connection with the database is lost and not recovered.
    error "Unrecoverable error occurred", error = msg
    quit(QuitFailure)

  #mount mix
  if conf.mixConf.isSome():
    let mixConf = conf.mixConf.get()
    var protection = Opt.none(SpamProtection)
    if mixConf.mixRlnConfig.isSome():
      node.protocols.mixRln = ModuleRlnProtection.new(
        mixConf.mixRlnConfig.get(), rlnMixCall
      ).valueOr:
        return err("failed to create Mix RLN adapter: " & error)
      protection = Opt.some(SpamProtection(node.protocols.mixRln))
    (await node.mountMix(conf.clusterId, mixConf.mixKey, mixConf.mixnodes, protection)).isOkOr:
      return err("failed to mount waku mix protocol: " & $error)

  # Setup service discovery
  if conf.kademliaDiscoveryConf.isSome():
    var kadConf = conf.kademliaDiscoveryConf.get()

    # Mix is no longer injected here: it is advertised at runtime through
    # IPeerDiscovery (see advertiseMix), so plugin-hosted kademlia gets it too.

    node.mountKademlia(kadConf).isOkOr:
      return err("failed to setup service discovery: " & error)

    node.attachDiscovery(ServicePeerDiscovery.create(node.discovery.kademlia))
    # The ServicePeersRequest provider is set by Kernel.start and cleared by
    # Kernel.stop (startProvidersAndListeners / stopProvidersAndListeners).

  if conf.storeServiceConf.isSome():
    let storeServiceConf = conf.storeServiceConf.get()

    let archiveDriver = (
      await driver.ArchiveDriver.new(
        storeServiceConf.dbUrl, storeServiceConf.dbVacuum, storeServiceConf.dbMigration,
        storeServiceConf.maxNumDbConnections, onFatalErrorAction,
      )
    ).valueOr:
      return err("failed to setup archive driver: " & error)

    let retPolicies = policy.RetentionPolicy.new(storeServiceConf.retentionPolicies).valueOr:
      return err("failed to create retention policy: " & error)

    node.mountArchive(archiveDriver, retPolicies).isOkOr:
      return err("failed to mount waku archive protocol: " & error)

    # Store setup
    try:
      await mountStore(node, node.rateLimitSettings.getSetting(STOREV3))
    except CatchableError:
      return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

    if storeServiceConf.storeSyncConf.isSome():
      let confStoreSync = storeServiceConf.storeSyncConf.get()

      (
        await node.mountStoreSync(
          conf.clusterId,
          conf.subscribeShards,
          conf.contentTopics,
          confStoreSync.rangeSec,
          confStoreSync.intervalSec,
          confStoreSync.relayJitterSec,
          int(conf.maxMessageSizeBytes),
        )
      ).isOkOr:
        return err("failed to mount waku store sync protocol: " & $error)

      if conf.remoteStoreNode.isSome():
        let storeNode = parsePeerInfo(conf.remoteStoreNode.get()).valueOr:
          return err("failed to set node waku store-sync peer: " & error)

        node.peerManager.addServicePeer(storeNode, WakuReconciliationCodec)
        node.peerManager.addServicePeer(storeNode, WakuTransferCodec)

  mountStoreClient(node, int(conf.maxMessageSizeBytes))
  if conf.remoteStoreNode.isSome():
    let storeNode = parsePeerInfo(conf.remoteStoreNode.get()).valueOr:
      return err("failed to set node waku store peer: " & error)
    node.peerManager.addServicePeer(storeNode, WakuStoreCodec)

  if conf.storeServiceConf.isSome and conf.storeServiceConf.get().resume:
    node.setupStoreResume()

  if conf.shardingConf.kind == AutoSharding:
    node.mountAutoSharding(conf.clusterId, conf.shardingConf.shards).isOkOr:
      return err("failed to mount waku auto sharding: " & error)
  else:
    info "Auto sharding is disabled"

  for shardId in conf.extraListenShards:
    node.subscriptionManager.extraListenShards.add(
      $RelayShard(clusterId: conf.clusterId, shardId: shardId)
    )

  # Mount relay on all nodes
  var peerExchangeHandler = Opt.none(RoutingRecordsHandler)
  if conf.relayPeerExchange:
    proc handlePeerExchange(
        peer: PeerId, topic: string, peers: seq[RoutingRecordsPair]
    ) {.gcsafe.} =
      ## Handle peers received via gossipsub peer exchange
      # TODO: Only consider peers on pubsub topics we subscribe to
      let exchangedPeers = peers.filterIt(it.record.isSome())
        # only peers with populated records
        .mapIt(toRemotePeerInfo(it.record.get()))

      debug "adding exchanged peers",
        src = peer, topic = topic, numPeers = exchangedPeers.len

      for peer in exchangedPeers:
        # Peers added are filtered by the peer manager
        node.peerManager.addPeer(peer, PeerOrigin.PeerExchange)

    peerExchangeHandler = Opt.some(handlePeerExchange)

  let shards = conf.subscribeShards.mapIt(
    RelayShard(clusterId: conf.clusterId, shardId: uint16(it))
  )

  if conf.relay:
    debug "Setting max message size", num_bytes = conf.maxMessageSizeBytes

    (
      await mountRelay(
        node, peerExchangeHandler = peerExchangeHandler, int(conf.maxMessageSizeBytes)
      )
    ).isOkOr:
      return err("failed to mount waku relay protocol: " & $error)

    # Add validation keys to protected topics
    var subscribedProtectedShards: seq[ProtectedShard]
    for shardKey in conf.protectedShards:
      if shardKey.shard notin conf.subscribeShards:
        warn "protected shard not in subscribed shards, skipping adding validator",
          protectedShard = shardKey.shard, subscribedShards = shards
        continue
      subscribedProtectedShards.add(shardKey)
      notice "routing only signed traffic",
        protectedShard = shardKey.shard, publicKey = shardKey.key
    node.protocols.relay.addSignedShardsValidator(
      subscribedProtectedShards, conf.clusterId
    )

  if conf.rendezvous:
    await node.mountRendezvous(conf.clusterId, shards)
    await node.mountRendezvousClient(conf.clusterId)

  # Keepalive mounted on all nodes
  try:
    await mountLibp2pPing(node)
  except CatchableError:
    return err("failed to mount libp2p ping protocol: " & getCurrentExceptionMsg())

  # RLN backend selected by configuration source: each descriptor probes
  # whether its own source is present — host callbacks installed over the C
  # ABI (`logosdelivery_rln_set_plugin`) for the external backend, CLI/preset
  # configuration for the on-chain one. With no source present the node starts
  # without RLN.
  let rlnDescriptors = [
    rlnLezDescriptor(),
    rlnEvmDescriptor(conf.rlnEvmConf, onFatalErrorAction, node.brokerCtx),
  ]

  let selectedRln = selectRlnPlugin(rlnDescriptors).valueOr:
    return err("failed call selectRlnPlugin: " & $error)

  if selectedRln.isNone():
    info "No RLN backend configured; RLN is off"
  else:
    when defined(disable_rln):
      return
        err("the configuration enables RLN relay, but this build has -d:disable_rln")
    else:
      let descriptor = selectedRln.get()
      info "Mounting RLN backend", backend = descriptor.name
      let mounted = (await descriptor.mount()).valueOr:
        return err("failed to mount RLN backend" & $error)
      node.mountRln(
        mounted, RlnCommonConf(disableValidation: conf.rlnDisableValidation)
      )

  # NOTE Must be mounted after relay
  if conf.lightPush:
    try:
      (await mountLightPush(node, node.rateLimitSettings.getSetting(LIGHTPUSH))).isOkOr:
        return err("failed to mount waku lightpush protocol: " & $error)

      (await mountLegacyLightPush(node, node.rateLimitSettings.getSetting(LIGHTPUSH))).isOkOr:
        return err("failed to mount waku legacy lightpush protocol: " & $error)
    except CatchableError:
      return err("failed to mount waku lightpush protocol: " & getCurrentExceptionMsg())

  mountLightPushClient(node)
  mountLegacyLightPushClient(node)
  if conf.remoteLightPushNode.isSome():
    let lightPushNode = parsePeerInfo(conf.remoteLightPushNode.get()).valueOr:
      return err("failed to set node waku lightpush peer: " & error)
    node.peerManager.addServicePeer(lightPushNode, WakuLightPushCodec)
    node.peerManager.addServicePeer(lightPushNode, WakuLegacyLightPushCodec)

  # Filter setup. NOTE Must be mounted after relay
  if conf.filterServiceConf.isSome():
    let confFilter = conf.filterServiceConf.get()
    try:
      await mountFilter(
        node,
        subscriptionTimeout = chronos.seconds(confFilter.subscriptionTimeout),
        maxFilterPeers = confFilter.maxPeersToServe,
        maxFilterCriteriaPerPeer = confFilter.maxCriteria,
        rateLimitSetting = node.rateLimitSettings.getSetting(FILTER),
      )
    except CatchableError:
      return err("failed to mount waku filter protocol: " & getCurrentExceptionMsg())

  await node.mountFilterClient()
  if conf.remoteFilterNode.isSome():
    let filterNode = parsePeerInfo(conf.remoteFilterNode.get()).valueOr:
      return err("failed to set node waku filter peer: " & error)
    try:
      node.peerManager.addServicePeer(filterNode, WakuFilterSubscribeCodec)
    except CatchableError:
      return
        err("failed to mount waku filter client protocol: " & getCurrentExceptionMsg())

  # waku peer exchange setup
  if conf.peerExchangeService:
    try:
      await mountPeerExchange(
        node, Opt.some(conf.clusterId), node.rateLimitSettings.getSetting(PEEREXCHG)
      )
    except CatchableError:
      return
        err("failed to mount waku peer-exchange protocol: " & getCurrentExceptionMsg())

  if conf.remotePeerExchangeNode.isSome():
    let peerExchangeNode = parsePeerInfo(conf.remotePeerExchangeNode.get()).valueOr:
      return err("failed to set node waku peer-exchange peer: " & error)
    node.peerManager.addServicePeer(peerExchangeNode, WakuPeerExchangeCodec)

  if conf.peerExchangeDiscovery:
    await node.mountPeerExchangeClient()

  return ok()

## Start node

proc startNode*(
    node: Kernel, conf: WakuConf, dynamicBootstrapNodes: seq[RemotePeerInfo] = @[]
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Start a configured node and all mounted protocols.
  ## Connect to static nodes and start keep-alive.

  info "Running nwaku node", version = git_version

  try:
    await node.startProtocols()
  except CatchableError:
    return err("failed to start waku node: " & getCurrentExceptionMsg())

  # Backend work that needs a running node, such as the external backend's
  # membership check, its first call to the host. The backend handles its own
  # failures, so the node starts regardless; only cancellation stops startup.
  if node.protocols.rlnPlugin.isSome() and
      not node.protocols.rlnPlugin.get().onNodeStarted.isNil():
    try:
      await node.protocols.rlnPlugin.get().onNodeStarted()
    except CancelledError:
      return err("cancelled during the RLN backend start hook")

  # Connect to configured static nodes
  if conf.staticNodes.len > 0:
    try:
      await connectToNodes(node, conf.staticNodes, "static")
    except CatchableError:
      return err("failed to connect to static nodes: " & getCurrentExceptionMsg())

  if dynamicBootstrapNodes.len > 0:
    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(node, dynamicBootstrapNodes, "dynamic bootstrap")
    except CatchableError:
      return
        err("failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg())

  # retrieve px peers and add the to the peer store
  if conf.remotePeerExchangeNode.isSome():
    var desiredOutDegree = DefaultPXNumPeersReq
    if not node.protocols.relay.isNil() and
        node.protocols.relay.parameters.d.uint64() > 0:
      desiredOutDegree = node.protocols.relay.parameters.d.uint64()
    (await node.fetchPeerExchangePeers(desiredOutDegree)).isOkOr:
      debug "error while fetching peers from peer exchange", error = error

  # TODO: behavior described by comment is undesired. PX as client should be used in tandem with discv5.
  #
  # Use px to periodically get peers if discv5 is disabled, as discv5 nodes have their own
  # periodic loop to find peers and px returned peers actually come from discv5
  if conf.peerExchangeDiscovery and not conf.discv5Conf.isSome():
    node.startPeerExchangeLoop()

  # Maintain relay connections
  if conf.relay:
    node.peerManager.start()

  return ok()

proc setupNode*(
    wakuConf: WakuConf, rng: crypto.Rng = crypto.newRng(), relay: Relay
): Future[Result[Kernel, string]] {.async.} =
  ## Libplum resolves an any strategy when the NAT service starts.
  wakuConf.endpointConf.natStrategy =
    await resolveNatStrategy(wakuConf.endpointConf.natStrategy)

  let netConfig = (
    await networkConfiguration(
      wakuConf.clusterId, wakuConf.endpointConf, wakuConf.discv5Conf,
      wakuConf.webSocketConf, wakuConf.quicConf, wakuConf.wakuFlags,
      wakuConf.dnsAddrsNameServers,
    )
  ).valueOr:
    error "failed to create internal config", error = error
    return err("failed to create internal config: " & error)

  let record = enrConfiguration(wakuConf, netConfig).valueOr:
    error "failed to create record", error = error
    return err("failed to create record: " & error)

  if isClusterMismatched(record, wakuConf.clusterId):
    error "cluster id mismatch configured shards"
    return err("cluster id mismatch configured shards")

  info "Setting up storage"

  ## Peer persistence
  var peerStore: Opt[WakuPeerStorage]
  if wakuConf.peerPersistence:
    peerStore = setupPeerStorage().valueOr:
      error "Setting up storage failed", error = "failed to setup peer store " & error
      return err("Setting up storage failed: " & error)

  info "Initializing node"

  let node = initNode(wakuConf, netConfig, rng, record, peerStore, relay).valueOr:
    error "Initializing node failed", error = error
    return err("Initializing node failed: " & error)

  info "Mounting protocols"

  try:
    (await node.setupProtocols(wakuConf)).isOkOr:
      error "Mounting protocols failed", error = error
      return err("Mounting protocols failed: " & error)
  except CatchableError:
    return err("Exception setting up protocols: " & getCurrentExceptionMsg())

  return ok(node)

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
  node.healthMonitor = monitor
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
  let (tcpPort, websocketPort, quicPort) = getPorts(kernel.switch.peerInfo.listenAddrs).valueOr:
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
  if not kernel.discovery.discv5.isNil():
    seqNum = max(seqNum, kernel.discovery.discv5.protocol.localNode.record.seqNum)

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
    let written = reconcileEnrAddrs(kernel, kernel.key, kernel.discovery.discv5).valueOr:
      error "failed to reconcile the ENR with the discv5 record", error = error
      continue
    if written:
      info "ENR reconciled with the discv5 record", enr = kernel.enr.toURI()
      kernel.logEnrReachability()

proc updateWaku(kernel: Kernel): Future[Result[void, string]] {.async.} =
  (await updateEnr(kernel)).isOkOr:
    return err("error calling updateEnr: " & $error)

  if not kernel.discovery.discv5.isNil():
    ## Copy the startup ENR into the live discv5 record once. Shard updates
    ## and multiaddr refreshes then update that record in place. The seed
    ## also gave discv5 its own address; the rebuild replaces that too.
    kernel.discovery.discv5.protocol.localNode.record = kernel.enr
    kernel.discovery.discv5.protocol.localNode.address = Opt.none(discv5_node.Address)
    ## Seeding is not learning: from here on, a record that moved is discv5's.
    kernel.enrLearnedEndpoint = Opt.none(DiscoveryEndpoint)

  ?refreshEnrAddrs(kernel, kernel.key, kernel.discovery.discv5)

  return ok()

proc startDnsDiscoveryRetryLoop(kernel: Kernel): Future[void] {.async.} =
  while true:
    await sleepAsync(30.seconds)
    if kernel.conf.dnsDiscoveryConf.isSome():
      let dnsDiscoveryConf = kernel.conf.dnsDiscoveryConf.get()
      kernel.discovery.dynamicBootstrapNodes = (
        await dnsdisc.retrieveDynamicBootstrapNodes(
          dnsDiscoveryConf.enrTreeUrl, kernel.conf.dnsAddrsNameServers
        )
      ).valueOr:
        debug "Retrieving dynamic bootstrap nodes failed", error = error
        continue

    if not kernel.discovery.discv5.isNil():
      let dynamicBootstrapEnrs = kernel.discovery.dynamicBootstrapNodes
        .filterIt(it.hasUdpPort())
        .mapIt(it.enr.get().toUri())
      var discv5BootstrapEnrs: seq[enr.Record]
      # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
      for enrUri in dynamicBootstrapEnrs:
        addBootstrapNode(enrUri, discv5BootstrapEnrs)

      kernel.discovery.discv5.updateBootstrapRecords(
        kernel.discovery.discv5.protocol.bootstrapRecords & discv5BootstrapEnrs
      )

    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(
        kernel, kernel.discovery.dynamicBootstrapNodes, "dynamic bootstrap"
      )
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

proc start*(kernel: Kernel): Future[Result[void, string]] {.async: (raises: []).} =
  if kernel.started:
    debug "start: waku node already started"
    return ok()

  if kernel.healthMonitor.isNil():
    ## A bare node, built without a conf, runs only its switch and protocols.
    try:
      await kernel.startProtocols()
    except CatchableError:
      return err("failed to start protocols: " & getCurrentExceptionMsg())
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
        await dnsdisc.retrieveDynamicBootstrapNodes(
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

  if not kernel.protocols.mixRln.isNil():
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

    kernel.discovery.discv5 = kernel.discovery.discv5Discovery.inner

    let discoveryInfo = (await kernel.discovery.discv5Discovery.backendInfo()).valueOr:
      return err("failed to read discv5 backend info: " & error)
    if discoveryInfo.boundPorts.len > 0:
      kernel.ports.discv5Udp = discoveryInfo.boundPorts[0]
      kernel.conf.discv5Conf.get().udpPort = Port(discoveryInfo.boundPorts[0])

  ## Set the callback before the explicit refresh in updateWaku,
  ## so a commit in between reaches the ENR.
  kernel.onCommittedAddresses = proc() {.gcsafe, raises: [].} =
    refreshEnrAddrs(kernel, kernel.key, kernel.discovery.discv5).isOkOr:
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

  if not kernel.discovery.discv5.isNil():
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
        protocol: ProtocolName
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
        await startMetricsServerAndLogging(conf.metricsServerConf.get())
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

proc stop*(kernel: Kernel): Future[Result[void, string]] {.async: (raises: []).} =
  if not kernel.started:
    debug "stop: attempting to stop node that isn't running"

  try:
    if not kernel.healthMonitor.isNil():
      kernel.healthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)

    kernel.closePersistency()

    if not kernel.metricsServer.isNil():
      await kernel.metricsServer.stop()

    # discv5 (as attached IPeerDiscovery backend) is stopped by node.stop()

    await kernel.stopMixRln()
    await kernel.stopProtocols()

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
