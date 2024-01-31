when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, strutils, sequtils],
  stew/results,
  chronicles,
  chronos,
  libp2p/wire,
  libp2p/multicodec,
  libp2p/crypto/crypto,
  libp2p/nameresolving/dnsresolver,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/peerid,
  eth/keys,
  json_rpc/rpcserver,
  presto,
  metrics,
  metrics/chronos_httpserver
import
  ../../waku/common/utils/nat,
  ../../waku/common/utils/parse_size_units,
  ../../waku/common/databases/db_sqlite,
  ../../waku/waku_archive/driver/builder,
  ../../waku/waku_archive/retention_policy/builder,
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/node/waku_metrics,
  ../../waku/node/peer_manager,
  ../../waku/node/peer_manager/peer_store/waku_peer_storage,
  ../../waku/node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../../waku/waku_api/message_cache,
  ../../waku/waku_api/handlers,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/debug/handlers as rest_debug_api,
  ../../waku/waku_api/rest/relay/handlers as rest_relay_api,
  ../../waku/waku_api/rest/filter/legacy_handlers as rest_legacy_filter_api,
  ../../waku/waku_api/rest/filter/handlers as rest_filter_api,
  ../../waku/waku_api/rest/lightpush/handlers as rest_lightpush_api,
  ../../waku/waku_api/rest/store/handlers as rest_store_api,
  ../../waku/waku_api/rest/health/handlers as rest_health_api,
  ../../waku/waku_api/rest/admin/handlers as rest_admin_api,
  ../../waku/waku_api/jsonrpc/admin/handlers as rpc_admin_api,
  ../../waku/waku_api/jsonrpc/debug/handlers as rpc_debug_api,
  ../../waku/waku_api/jsonrpc/filter/handlers as rpc_filter_api,
  ../../waku/waku_api/jsonrpc/relay/handlers as rpc_relay_api,
  ../../waku/waku_api/jsonrpc/store/handlers as rpc_store_api,
  ../../waku/waku_archive,
  ../../waku/waku_dnsdisc,
  ../../waku/waku_enr/sharding,
  ../../waku/waku_discv5,
  ../../waku/waku_peer_exchange,
  ../../waku/waku_rln_relay,
  ../../waku/waku_store,
  ../../waku/waku_lightpush/common,
  ../../waku/waku_filter,
  ../../waku/waku_filter_v2,
  ./wakunode2_validator_signed,
  ./internal_config,
  ./external_config

logScope:
  topics = "wakunode app"


# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

type
  App* = object
    version: string
    conf: WakuNodeConf
    netConf: NetConfig
    rng: ref HmacDrbgContext
    key: crypto.PrivateKey
    record: Record

    wakuDiscv5: Option[WakuDiscoveryV5]
    peerStore: Option[WakuPeerStorage]
    dynamicBootstrapNodes: seq[RemotePeerInfo]

    node: WakuNode

    rpcServer: Option[RpcHttpServer]
    restServer: Option[RestServerRef]
    metricsServer: Option[MetricsHttpServerRef]

  AppResult*[T] = Result[T, string]


func node*(app: App): WakuNode =
  app.node

func version*(app: App): string =
  app.version


## Initialisation

proc init*(T: type App, rng: ref HmacDrbgContext, conf: WakuNodeConf): T =
  let key =
    if conf.nodeKey.isSome():
      conf.nodeKey.get()
    else:
      let keyRes = crypto.PrivateKey.random(Secp256k1, rng[])

      if keyRes.isErr():
        error "failed to generate key", error=keyRes.error
        quit(QuitFailure)

      keyRes.get()

  let netConfigRes = networkConfiguration(conf, clientId)

  let netConfig =
    if netConfigRes.isErr():
      error "failed to create internal config", error=netConfigRes.error
      quit(QuitFailure)
    else: netConfigRes.get()

  let recordRes = enrConfiguration(conf, netConfig, key)

  let record =
    if recordRes.isErr():
      error "failed to create record", error=recordRes.error
      quit(QuitFailure)
    else: recordRes.get()

  if isClusterMismatched(record, conf.clusterId):
    error "cluster id mismatch configured shards"
    quit(QuitFailure)

  App(
    version: git_version,
    conf: conf,
    netConf: netConfig,
    rng: rng,
    key: key,
    record: record,
    node: nil
  )


## Peer persistence

const PeerPersistenceDbUrl = "peers.db"
proc setupPeerStorage(): AppResult[Option[WakuPeerStorage]] =
  let db = ? SqliteDatabase.new(PeerPersistenceDbUrl)

  ? peer_store_sqlite_migrations.migrate(db)

  let res = WakuPeerStorage.new(db)
  if res.isErr():
    return err("failed to init peer store" & res.error)

  ok(some(res.value))

proc setupPeerPersistence*(app: var App): AppResult[void] =
  if not app.conf.peerPersistence:
    return ok()

  let peerStoreRes = setupPeerStorage()
  if peerStoreRes.isErr():
    return err("failed to setup peer store" & peerStoreRes.error)

  app.peerStore = peerStoreRes.get()

  ok()

## Retrieve dynamic bootstrap nodes (DNS discovery)

proc retrieveDynamicBootstrapNodes*(dnsDiscovery: bool,
                                    dnsDiscoveryUrl: string,
                                    dnsDiscoveryNameServers: seq[IpAddress]):
                                    AppResult[seq[RemotePeerInfo]] =

  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url=dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain=domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers()
        .mapErr(proc (e: cstring): string = $e)
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

proc setupDyamicBootstrapNodes*(app: var App): AppResult[void] =
  let dynamicBootstrapNodesRes = retrieveDynamicBootstrapNodes(app.conf.dnsDiscovery,
                                                               app.conf.dnsDiscoveryUrl,
                                                               app.conf.dnsDiscoveryNameServers)
  if dynamicBootstrapNodesRes.isOk():
    app.dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()
  else:
    warn "2/7 Retrieving dynamic bootstrap nodes failed. Continuing without dynamic bootstrap nodes.", error=dynamicBootstrapNodesRes.error

  ok()

## Setup DiscoveryV5

proc setupDiscoveryV5*(app: App): WakuDiscoveryV5 =
  let dynamicBootstrapEnrs = app.dynamicBootstrapNodes
                                .filterIt(it.hasUdpPort())
                                .mapIt(it.enr.get())

  var discv5BootstrapEnrs: seq[enr.Record]

  # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
  for enrUri in app.conf.discv5BootstrapNodes:
    addBootstrapNode(enrUri, discv5BootstrapEnrs)

  discv5BootstrapEnrs.add(dynamicBootstrapEnrs)

  let discv5Config = DiscoveryConfig.init(app.conf.discv5TableIpLimit,
                                          app.conf.discv5BucketIpLimit,
                                          app.conf.discv5BitsPerHop)

  let discv5UdpPort = Port(uint16(app.conf.discv5UdpPort) + app.conf.portsShift)

  let discv5Conf = WakuDiscoveryV5Config(
    discv5Config: some(discv5Config),
    address: app.conf.listenAddress,
    port: discv5UdpPort,
    privateKey: keys.PrivateKey(app.key.skkey),
    bootstrapRecords: discv5BootstrapEnrs,
    autoupdateRecord: app.conf.discv5EnrAutoUpdate,
  )

  WakuDiscoveryV5.new(
    app.rng,
    discv5Conf,
    some(app.record),
    some(app.node.peerManager),
    app.node.topicSubscriptionQueue,
  )

## Init waku node instance

proc initNode(conf: WakuNodeConf,
              netConfig: NetConfig,
              rng: ref HmacDrbgContext,
              nodeKey: crypto.PrivateKey,
              record: enr.Record,
              peerStore: Option[WakuPeerStorage],
              dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[]): AppResult[WakuNode] =

  ## Setup a basic Waku v2 node based on a supplied configuration
  ## file. Optionally include persistent peer storage.
  ## No protocols are mounted yet.

  var dnsResolver: DnsResolver
  if conf.dnsAddrs:
    # Support for DNS multiaddrs
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsAddrsNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    dnsResolver = DnsResolver.new(nameServers)

  var node: WakuNode

  let pStorage = if peerStore.isNone(): nil
                 else: peerStore.get()

  # Build waku node instance
  var builder = WakuNodeBuilder.init()
  builder.withRng(rng)
  builder.withNodeKey(nodekey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig)
  builder.withPeerStorage(pStorage, capacity = conf.peerStoreCapacity)
  builder.withSwitchConfiguration(
      maxConnections = some(conf.maxConnections.int),
      secureKey = some(conf.websocketSecureKeyPath),
      secureCert = some(conf.websocketSecureCertPath),
      nameResolver = dnsResolver,
      sendSignedPeerRecord = conf.relayPeerExchange, # We send our own signed peer record when peer exchange enabled
      agentString = some(conf.agentString)
  )
  builder.withColocationLimit(conf.colocationLimit)
  builder.withPeerManagerConfig(
    maxRelayPeers = conf.maxRelayPeers,
    shardAware = conf.relayShardedPeerManagement,)

  node = ? builder.build().mapErr(proc (err: string): string = "failed to create waku node instance: " & err)

  ok(node)

proc setupWakuApp*(app: var App): AppResult[void] =
  ## Waku node
  let initNodeRes = initNode(app.conf, app.netConf, app.rng, app.key, app.record, app.peerStore, app.dynamicBootstrapNodes)
  if initNodeRes.isErr():
    return err("failed to init node: " & initNodeRes.error)

  app.node = initNodeRes.get()

  ## Discv5
  if app.conf.discv5Discovery:
    app.wakuDiscV5 = some(app.setupDiscoveryV5())

  ok()

proc getPorts(listenAddrs: seq[MultiAddress]):
              AppResult[tuple[tcpPort, websocketPort: Option[Port]]] =

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

proc updateNetConfig(app: var App): AppResult[void] =

  var conf = app.conf
  let (tcpPort, websocketPort) = getPorts(app.node.switch.peerInfo.listenAddrs).valueOr:
    return err("Could not retrieve ports " & error)

  if tcpPort.isSome():
    conf.tcpPort = tcpPort.get()

  if websocketPort.isSome():
    conf.websocketPort = websocketPort.get()

  # Rebuild NetConfig with bound port values
  let netConf = networkConfiguration(conf, clientId).valueOr:
    return err("Could not update NetConfig: " & error)

  app.netConf = netConf

  return ok()

proc updateEnr(app: var App): AppResult[void] =

  let record = enrConfiguration(app.conf, app.netConf, app.key).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, app.conf.clusterId):
    return err("cluster id mismatch configured shards")

  app.record = record
  app.node.enr = record

  if app.conf.discv5Discovery:
    app.wakuDiscV5 = some(app.setupDiscoveryV5())

  return ok()

proc updateApp(app: var App): AppResult[void] =

  if app.conf.tcpPort == Port(0) or app.conf.websocketPort == Port(0):

    updateNetConfig(app).isOkOr:
      return err("error calling updateNetConfig: " & $error)

    updateEnr(app).isOkOr:
      return err("error calling updateEnr: " & $error)

    app.node.announcedAddresses = app.netConf.announcedAddresses

    printNodeNetworkInfo(app.node)

  return ok()

## Mount protocols

proc setupProtocols(node: WakuNode,
                    conf: WakuNodeConf,
                    nodeKey: crypto.PrivateKey):
                    Future[AppResult[void]] {.async.} =
  ## Setup configured protocols on an existing Waku v2 node.
  ## Optionally include persistent message storage.
  ## No protocols are started yet.

  node.mountMetadata(conf.clusterId).isOkOr:
    return err("failed to mount waku metadata protocol: " & error)

  # Mount relay on all nodes
  var peerExchangeHandler = none(RoutingRecordsHandler)
  if conf.relayPeerExchange:
    proc handlePeerExchange(peer: PeerId, topic: string,
                            peers: seq[RoutingRecordsPair]) {.gcsafe.} =
      ## Handle peers received via gossipsub peer exchange
      # TODO: Only consider peers on pubsub topics we subscribe to
      let exchangedPeers = peers.filterIt(it.record.isSome()) # only peers with populated records
                                .mapIt(toRemotePeerInfo(it.record.get()))

      debug "connecting to exchanged peers", src=peer, topic=topic, numPeers=exchangedPeers.len

      # asyncSpawn, as we don't want to block here
      asyncSpawn node.connectToNodes(exchangedPeers, "peer exchange")

    peerExchangeHandler = some(handlePeerExchange)

  if conf.relay:
    let pubsubTopics =
      if conf.pubsubTopics.len > 0 or conf.contentTopics.len > 0:
        # TODO autoshard content topics only once.
        # Already checked for errors in app.init
        let shards = conf.contentTopics.mapIt(getShard(it).expect("Valid Shard"))
        conf.pubsubTopics & shards
      else:
        conf.topics

    let parsedMaxMsgSize = parseMsgSize(conf.maxMessageSize).valueOr:
      return err("failed to parse 'max-num-bytes-msg-size' param: " & $error)

    debug "Setting max message size", num_bytes=parsedMaxMsgSize

    try:
      await mountRelay(node, pubsubTopics, peerExchangeHandler = peerExchangeHandler,
                       int(parsedMaxMsgSize))
    except CatchableError:
      return err("failed to mount waku relay protocol: " & getCurrentExceptionMsg())

    # Add validation keys to protected topics
    var subscribedProtectedTopics : seq[ProtectedTopic]
    for topicKey in conf.protectedTopics:
      if topicKey.topic notin pubsubTopics:
        warn "protected topic not in subscribed pubsub topics, skipping adding validator",
              protectedTopic=topicKey.topic, subscribedTopics=pubsubTopics
        continue
      subscribedProtectedTopics.add(topicKey)
      notice "routing only signed traffic", protectedTopic=topicKey.topic, publicKey=topicKey.key
    node.wakuRelay.addSignedTopicsValidator(subscribedProtectedTopics)

    # Enable Rendezvous Discovery protocol when Relay is enabled
    try:
      await mountRendezvous(node)
    except CatchableError:
      return err("failed to mount waku rendezvous protocol: " & getCurrentExceptionMsg())

  # Keepalive mounted on all nodes
  try:
    await mountLibp2pPing(node)
  except CatchableError:
    return err("failed to mount libp2p ping protocol: " & getCurrentExceptionMsg())

  if conf.rlnRelay:

    let rlnConf = WakuRlnConfig(
      rlnRelayDynamic: conf.rlnRelayDynamic,
      rlnRelayCredIndex: conf.rlnRelayCredIndex,
      rlnRelayEthContractAddress: conf.rlnRelayEthContractAddress,
      rlnRelayEthClientAddress: conf.rlnRelayEthClientAddress,
      rlnRelayCredPath: conf.rlnRelayCredPath,
      rlnRelayCredPassword: conf.rlnRelayCredPassword,
      rlnRelayTreePath: conf.rlnRelayTreePath,
    )

    try:
      waitFor node.mountRlnRelay(rlnConf)
    except CatchableError:
      return err("failed to mount waku RLN relay protocol: " & getCurrentExceptionMsg())

  if conf.store:
    var onErrAction = proc(msg: string) {.gcsafe, closure.} =
      ## Action to be taken when an internal error occurs during the node run.
      ## e.g. the connection with the database is lost and not recovered.
      error "Unrecoverable error occurred", error = msg
      quit(QuitFailure)

    # Archive setup
    let archiveDriverRes = ArchiveDriver.new(conf.storeMessageDbUrl,
                                             conf.storeMessageDbVacuum,
                                             conf.storeMessageDbMigration,
                                             conf.storeMaxNumDbConnections,
                                             onErrAction)
    if archiveDriverRes.isErr():
      return err("failed to setup archive driver: " & archiveDriverRes.error)

    let retPolicyRes = RetentionPolicy.new(conf.storeMessageRetentionPolicy)
    if retPolicyRes.isErr():
      return err("failed to create retention policy: " & retPolicyRes.error)

    let mountArcRes = node.mountArchive(archiveDriverRes.get(),
                                        retPolicyRes.get())
    if mountArcRes.isErr():
      return err("failed to mount waku archive protocol: " & mountArcRes.error)

    # Store setup
    try:
      await mountStore(node)
    except CatchableError:
      return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

  mountStoreClient(node)
  if conf.storenode != "":
    let storeNode = parsePeerInfo(conf.storenode)
    if storeNode.isOk():
      node.peerManager.addServicePeer(storeNode.value, WakuStoreCodec)
    else:
      return err("failed to set node waku store peer: " & storeNode.error)

  # NOTE Must be mounted after relay
  if conf.lightpush:
    try:
      await mountLightPush(node)
    except CatchableError:
      return err("failed to mount waku lightpush protocol: " & getCurrentExceptionMsg())

  if conf.lightpushnode != "":
    let lightPushNode = parsePeerInfo(conf.lightpushnode)
    if lightPushNode.isOk():
      mountLightPushClient(node)
      node.peerManager.addServicePeer(lightPushNode.value, WakuLightPushCodec)
    else:
      return err("failed to set node waku lightpush peer: " & lightPushNode.error)

  # Filter setup. NOTE Must be mounted after relay
  if conf.filter:
    try:
      await mountLegacyFilter(node, filterTimeout = chronos.seconds(conf.filterTimeout))
    except CatchableError:
      return err("failed to mount waku legacy filter protocol: " & getCurrentExceptionMsg())

    try:
      await mountFilter(node,
                        subscriptionTimeout = chronos.seconds(conf.filterSubscriptionTimeout),
                        maxFilterPeers = conf.filterMaxPeersToServe,
                        maxFilterCriteriaPerPeer = conf.filterMaxCriteria)
    except CatchableError:
      return err("failed to mount waku filter protocol: " & getCurrentExceptionMsg())

  if conf.filternode != "":
    let filterNode = parsePeerInfo(conf.filternode)
    if filterNode.isOk():
      try:
        await node.mountFilterClient()
        node.peerManager.addServicePeer(filterNode.value, WakuLegacyFilterCodec)
        node.peerManager.addServicePeer(filterNode.value, WakuFilterSubscribeCodec)
      except CatchableError:
        return err("failed to mount waku filter client protocol: " & getCurrentExceptionMsg())
    else:
      return err("failed to set node waku filter peer: " & filterNode.error)

  # waku peer exchange setup
  if conf.peerExchangeNode != "" or conf.peerExchange:
    try:
      await mountPeerExchange(node)
    except CatchableError:
      return err("failed to mount waku peer-exchange protocol: " & getCurrentExceptionMsg())

    if conf.peerExchangeNode != "":
      let peerExchangeNode = parsePeerInfo(conf.peerExchangeNode)
      if peerExchangeNode.isOk():
        node.peerManager.addServicePeer(peerExchangeNode.value, WakuPeerExchangeCodec)
      else:
        return err("failed to set node waku peer-exchange peer: " & peerExchangeNode.error)

  return ok()

proc setupAndMountProtocols*(app: App): Future[AppResult[void]] {.async.} =
  return await setupProtocols(
    app.node,
    app.conf,
    app.key
  )

## Start node

proc startNode(node: WakuNode, conf: WakuNodeConf,
               dynamicBootstrapNodes: seq[RemotePeerInfo] = @[]): Future[AppResult[void]] {.async.} =
  ## Start a configured node and all mounted protocols.
  ## Connect to static nodes and start
  ## keep-alive, if configured.

  # Start Waku v2 node
  try:
    await node.start()
  except CatchableError:
    return err("failed to start waku node: " & getCurrentExceptionMsg())

  # Connect to configured static nodes
  if conf.staticnodes.len > 0:
    try:
      await connectToNodes(node, conf.staticnodes, "static")
    except CatchableError:
      return err("failed to connect to static nodes: " & getCurrentExceptionMsg())

  if dynamicBootstrapNodes.len > 0:
    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(node, dynamicBootstrapNodes, "dynamic bootstrap")
    except CatchableError:
      return err("failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg())

  # retrieve px peers and add the to the peer store
  if conf.peerExchangeNode != "":
    let desiredOutDegree = node.wakuRelay.parameters.d.uint64()
    await node.fetchPeerExchangePeers(desiredOutDegree)

  # Start keepalive, if enabled
  if conf.keepAlive:
    node.startKeepalive()

  # Maintain relay connections
  if conf.relay:
    node.peerManager.start()

  return ok()

proc startApp*(app: var App): AppResult[void] =

  let nodeRes = catch: (waitFor startNode(app.node,app.conf,app.dynamicBootstrapNodes))
  if nodeRes.isErr():
    return err("exception starting node: " & nodeRes.error.msg)

  nodeRes.get().isOkOr:
    return err("exception starting node: " & error)

  # Update app data that is set dynamically on node start
  app.updateApp().isOkOr:
    return err("Error in updateApp: " & $error)

  if app.wakuDiscv5.isSome():
    let wakuDiscv5 = app.wakuDiscv5.get()
    let catchRes = catch: (waitFor wakuDiscv5.start())
    let startRes = catchRes.valueOr:
      return err("failed to start waku discovery v5: " & catchRes.error.msg)

    startRes.isOkOr:
      return err("failed to start waku discovery v5: " & error)

  return ok()



## Monitoring and external interfaces

proc startRestServer(app: App, address: IpAddress, port: Port, conf: WakuNodeConf): AppResult[RestServerRef] =

  # Used to register api endpoints that are not currently installed as keys,
  # values are holding error messages to be returned to the client
  var notInstalledTab: Table[string, string] = initTable[string, string]()

  proc requestErrorHandler(error: RestRequestError,
                                request: HttpRequestRef):
                                Future[HttpResponseRef] {.async.} =
    case error
    of RestRequestError.Invalid:
      return await request.respond(Http400, "Invalid request", HttpTable.init())
    of RestRequestError.NotFound:
      let rootPath = request.rawPath.split("/")[1]
      if notInstalledTab.hasKey(rootPath):
        return await request.respond(Http404, notInstalledTab[rootPath], HttpTable.init())
      else:
        return await request.respond(Http400, "Bad request initiated. Invalid path or method used.", HttpTable.init())
    of RestRequestError.InvalidContentBody:
      return await request.respond(Http400, "Invalid content body", HttpTable.init())
    of RestRequestError.InvalidContentType:
      return await request.respond(Http400, "Invalid content type", HttpTable.init())
    of RestRequestError.Unexpected:
      return defaultResponse()

    return defaultResponse()

  let server = ? newRestHttpServer(address, port, requestErrorHandler = requestErrorHandler)
  ## Admin REST API
  if conf.restAdmin:
    installAdminApiHandlers(server.router, app.node)

  ## Debug REST API
  installDebugApiHandlers(server.router, app.node)

  ## Health REST API
  installHealthApiHandler(server.router, app.node)

  ## Relay REST API
  if conf.relay:
    let cache = MessageCache.init(int(conf.restRelayCacheCapacity))

    let handler = messageCacheHandler(cache)

    for pubsubTopic in conf.pubsubTopics:
      cache.pubsubSubscribe(pubsubTopic)
      app.node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(handler))

    for contentTopic in conf.contentTopics:
      cache.contentSubscribe(contentTopic)
      app.node.subscribe((kind: ContentSub, topic: contentTopic), some(handler))

    installRelayApiHandlers(server.router, app.node, cache)
  else:
    notInstalledTab["relay"] = "/relay endpoints are not available. Please check your configuration: --relay"

  ## Filter REST API
  if conf.filternode  != "" and
     app.node.wakuFilterClient != nil and
     app.node.wakuFilterClientLegacy != nil:

    let legacyFilterCache = MessageCache.init()
    rest_legacy_filter_api.installLegacyFilterRestApiHandlers(server.router, app.node, legacyFilterCache)

    let filterCache = MessageCache.init()

    let filterDiscoHandler =
      if app.wakuDiscv5.isSome():
        some(defaultDiscoveryHandler(app.wakuDiscv5.get(), Filter))
      else: none(DiscoveryHandler)

    rest_filter_api.installFilterRestApiHandlers(
      server.router,
      app.node,
      filterCache,
      filterDiscoHandler,
    )
  else:
    notInstalledTab["filter"] = "/filter endpoints are not available. Please check your configuration: --filternode"

  ## Store REST API
  let storeDiscoHandler =
    if app.wakuDiscv5.isSome():
      some(defaultDiscoveryHandler(app.wakuDiscv5.get(), Store))
    else: none(DiscoveryHandler)

  installStoreApiHandlers(server.router, app.node, storeDiscoHandler)

  ## Light push API
  if conf.lightpushnode  != "" and
     app.node.wakuLightpushClient != nil:
    let lightDiscoHandler =
      if app.wakuDiscv5.isSome():
        some(defaultDiscoveryHandler(app.wakuDiscv5.get(), Lightpush))
      else: none(DiscoveryHandler)

    rest_lightpush_api.installLightPushRequestHandler(server.router, app.node, lightDiscoHandler)
  else:
    notInstalledTab["lightpush"] = "/lightpush endpoints are not available. Please check your configuration: --lightpushnode"

  server.start()
  info "Starting REST HTTP server", url = "http://" & $address & ":" & $port & "/"

  ok(server)

proc startRpcServer(app: App, address: IpAddress, port: Port, conf: WakuNodeConf): AppResult[RpcHttpServer] =
  let ta = initTAddress(address, port)

  var server: RpcHttpServer
  try:
    server = newRpcHttpServer([ta])
  except CatchableError:
    return err("failed to init JSON-RPC server: " & getCurrentExceptionMsg())

  installDebugApiHandlers(app.node, server)

  if conf.relay:
    let cache = MessageCache.init(capacity=50)

    let handler = messageCacheHandler(cache)

    for pubsubTopic in conf.pubsubTopics:
      cache.pubsubSubscribe(pubsubTopic)
      app.node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(handler))

    for contentTopic in conf.contentTopics:
      cache.contentSubscribe(contentTopic)
      app.node.subscribe((kind: ContentSub, topic: contentTopic), some(handler))

    installRelayApiHandlers(app.node, server, cache)

  if conf.filternode != "":
    let filterMessageCache = MessageCache.init(capacity=50)
    installFilterApiHandlers(app.node, server, filterMessageCache)

  installStoreApiHandlers(app.node, server)

  if conf.rpcAdmin:
    installAdminApiHandlers(app.node, server)

  server.start()
  info "RPC Server started", address=ta

  ok(server)

proc startMetricsServer(serverIp: IpAddress, serverPort: Port): AppResult[MetricsHttpServerRef] =
  info "Starting metrics HTTP server", serverIp= $serverIp, serverPort= $serverPort

  let metricsServerRes = MetricsHttpServerRef.new($serverIp, serverPort)
  if metricsServerRes.isErr():
    return err("metrics HTTP server start failed: " & $metricsServerRes.error)

  let server = metricsServerRes.value
  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp= $serverIp, serverPort= $serverPort
  ok(server)

proc startMetricsLogging(): AppResult[void] =
  startMetricsLog()
  ok()

proc setupMonitoringAndExternalInterfaces*(app: var App): AppResult[void] =
  if app.conf.rpc:
    let startRpcServerRes = startRpcServer(app, app.conf.rpcAddress, Port(app.conf.rpcPort + app.conf.portsShift), app.conf)
    if startRpcServerRes.isErr():
      error "6/7 Starting JSON-RPC server failed. Continuing in current state.", error=startRpcServerRes.error
    else:
      app.rpcServer = some(startRpcServerRes.value)

  if app.conf.rest:
    let startRestServerRes = startRestServer(app, app.conf.restAddress, Port(app.conf.restPort + app.conf.portsShift), app.conf)
    if startRestServerRes.isErr():
      error "6/7 Starting REST server failed. Continuing in current state.", error=startRestServerRes.error
    else:
      app.restServer = some(startRestServerRes.value)


  if app.conf.metricsServer:
    let startMetricsServerRes = startMetricsServer(app.conf.metricsServerAddress, Port(app.conf.metricsServerPort + app.conf.portsShift))
    if startMetricsServerRes.isErr():
      error "6/7 Starting metrics server failed. Continuing in current state.", error=startMetricsServerRes.error
    else:
      app.metricsServer = some(startMetricsServerRes.value)

  if app.conf.metricsLogging:
    let startMetricsLoggingRes = startMetricsLogging()
    if startMetricsLoggingRes.isErr():
      error "6/7 Starting metrics console logging failed. Continuing in current state.", error=startMetricsLoggingRes.error

  ok()


# App shutdown

proc stop*(app: App): Future[void] {.async: (raises: [Exception]).} =
  if app.restServer.isSome():
    await app.restServer.get().stop()

  if app.rpcServer.isSome():
    await app.rpcServer.get().stop()

  if app.metricsServer.isSome():
    await app.metricsServer.get().stop()

  if app.wakuDiscv5.isSome():
    await app.wakuDiscv5.get().stop()

  if not app.node.isNil():
    await app.node.stop()
