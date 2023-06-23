when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, strutils, sequtils],
  stew/results,
  chronicles,
  chronos,
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
  ../../waku/common/databases/db_sqlite,
  ../../waku/v2/waku_archive/driver_builder,
  ../../waku/v2/waku_archive/retention_policy_builder,
  ../../waku/v2/waku_core,
  ../../waku/v2/waku_node,
  ../../waku/v2/node/waku_metrics,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ../../waku/v2/node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../../waku/v2/waku_archive,
  ../../waku/v2/waku_dnsdisc,
  ../../waku/v2/waku_enr,
  ../../waku/v2/waku_discv5,
  ../../waku/v2/waku_peer_exchange,
  ../../waku/v2/waku_store,
  ../../waku/v2/waku_lightpush,
  ../../waku/v2/waku_filter,
  ./wakunode2_validator_signed,
  ./internal_config,
  ./external_config
import
  ../../waku/v2/node/message_cache,
  ../../waku/v2/node/rest/server,
  ../../waku/v2/node/rest/debug/handlers as rest_debug_api,
  ../../waku/v2/node/rest/relay/handlers as rest_relay_api,
  ../../waku/v2/node/rest/relay/topic_cache,
  ../../waku/v2/node/rest/store/handlers as rest_store_api,
  ../../waku/v2/node/jsonrpc/admin/handlers as rpc_admin_api,
  ../../waku/v2/node/jsonrpc/debug/handlers as rpc_debug_api,
  ../../waku/v2/node/jsonrpc/filter/handlers as rpc_filter_api,
  ../../waku/v2/node/jsonrpc/relay/handlers as rpc_relay_api,
  ../../waku/v2/node/jsonrpc/store/handlers as rpc_store_api

when defined(rln):
  import ../../waku/v2/waku_rln_relay

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

  let netConfigRes = networkConfiguration(conf)
  let netConfig =
    if netConfigRes.isErr():
      error "failed to create internal config", error=netConfigRes.error
      quit(QuitFailure)
    else: netConfigRes.get()

  let recordRes = createRecord(conf, netConfig, key)
  let record =
    if recordRes.isErr():
      error "failed to create record", error=recordRes.error
      quit(QuitFailure)
    else: recordRes.get()

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

proc setupPeerStorage(): AppResult[Option[WakuPeerStorage]] =
  let db = ? SqliteDatabase.new("peers.db")

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

proc retrieveDynamicBootstrapNodes*(dnsDiscovery: bool, dnsDiscoveryUrl: string, dnsDiscoveryNameServers: seq[ValidIpAddress]): AppResult[seq[RemotePeerInfo]] =

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

  var wakuDiscv5 = none(WakuDiscoveryV5)

  if conf.discv5Discovery:
    let dynamicBootstrapEnrs = dynamicBootstrapNodes
                                .filterIt(it.hasUdpPort())
                                .mapIt(it.enr.get())
    var discv5BootstrapEnrs: seq[enr.Record]
    # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
    for enrUri in conf.discv5BootstrapNodes:
      addBootstrapNode(enrUri, discv5BootstrapEnrs)
    discv5BootstrapEnrs.add(dynamicBootstrapEnrs)
    let discv5Config = DiscoveryConfig.init(conf.discv5TableIpLimit,
                                            conf.discv5BucketIpLimit,
                                            conf.discv5BitsPerHop)
    try:
      wakuDiscv5 = some(WakuDiscoveryV5.new(
        extIp = netConfig.extIp,
        extTcpPort = netConfig.extPort,
        extUdpPort = netConfig.discv5UdpPort,
        bindIp = netConfig.bindIp,
        discv5UdpPort = netConfig.discv5UdpPort.get(),
        bootstrapEnrs = discv5BootstrapEnrs,
        enrAutoUpdate = conf.discv5EnrAutoUpdate,
        privateKey = keys.PrivateKey(nodekey.skkey),
        flags = netConfig.wakuFlags.get(),
        multiaddrs = netConfig.enrMultiaddrs,
        rng = rng,
        conf.topics,
        discv5Config = discv5Config
      ))
    except CatchableError:
      return err("failed to create waku discv5 instance: " & getCurrentExceptionMsg())

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
  builder.withWakuDiscv5(wakuDiscv5.get(nil))
  builder.withPeerManagerConfig(maxRelayPeers = some(conf.maxRelayPeers.int))

  node = ? builder.build().mapErr(proc (err: string): string = "failed to create waku node instance: " & err)

  ok(node)

proc setupWakuNode*(app: var App): AppResult[void] =
  ## Waku node
  let initNodeRes = initNode(app.conf, app.netConf, app.rng, app.key, app.record, app.peerStore, app.dynamicBootstrapNodes)
  if initNodeRes.isErr():
    return err("failed to init node: " & initNodeRes.error)

  app.node = initNodeRes.get()
  ok()


## Mount protocols

proc setupProtocols(node: WakuNode,
                    conf: WakuNodeConf,
                    nodeKey: crypto.PrivateKey):
                    Future[AppResult[void]] {.async.} =
  ## Setup configured protocols on an existing Waku v2 node.
  ## Optionally include persistent message storage.
  ## No protocols are started yet.

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
    let pubsubTopics = conf.topics
    try:
      await mountRelay(node, pubsubTopics, peerExchangeHandler = peerExchangeHandler)
    except CatchableError:
      return err("failed to mount waku relay protocol: " & getCurrentExceptionMsg())

    # Add validation keys to protected topics
    for topicKey in conf.protectedTopics:
      if topicKey.topic notin pubsubTopics:
        warn "protected topic not in subscribed pubsub topics, skipping adding validator",
              protectedTopic=topicKey.topic, subscribedTopics=pubsubTopics
        continue
      notice "routing only signed traffic", protectedTopic=topicKey.topic, publicKey=topicKey.key
      node.wakuRelay.addSignedTopicValidator(Pubsubtopic(topicKey.topic), topicKey.key)

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

  when defined(rln):
    if conf.rlnRelay:

      let rlnConf = WakuRlnConfig(
        rlnRelayDynamic: conf.rlnRelayDynamic,
        rlnRelayPubsubTopic: conf.rlnRelayPubsubTopic,
        rlnRelayContentTopic: conf.rlnRelayContentTopic,
        rlnRelayCredIndex: conf.rlnRelayCredIndex,
        rlnRelayMembershipGroupIndex: conf.rlnRelayMembershipGroupIndex,
        rlnRelayEthContractAddress: conf.rlnRelayEthContractAddress,
        rlnRelayEthClientAddress: conf.rlnRelayEthClientAddress,
        rlnRelayEthAccountPrivateKey: conf.rlnRelayEthAccountPrivateKey,
        rlnRelayEthAccountAddress: conf.rlnRelayEthAccountAddress,
        rlnRelayCredPath: conf.rlnRelayCredPath,
        rlnRelayCredentialsPassword: conf.rlnRelayCredentialsPassword,
        rlnRelayTreePath: conf.rlnRelayTreePath
      )

      try:
        await node.mountRlnRelay(rlnConf)
      except CatchableError:
        return err("failed to mount waku RLN relay protocol: " & getCurrentExceptionMsg())

  if conf.store:
    # Archive setup
    let archiveDriverRes = ArchiveDriver.new(conf.storeMessageDbUrl,
                                             conf.storeMessageDbVacuum,
                                             conf.storeMessageDbMigration)
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
      await mountFilter(node, filterTimeout = chronos.seconds(conf.filterTimeout))
    except CatchableError:
      return err("failed to mount waku filter protocol: " & getCurrentExceptionMsg())

  if conf.filternode != "":
    let filterNode = parsePeerInfo(conf.filternode)
    if filterNode.isOk():
      await mountFilterClient(node)
      node.peerManager.addServicePeer(filterNode.value, WakuFilterCodec)
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

  # Start discv5 based discovery service (discovery loop)
  if conf.discv5Discovery:
    let startDiscv5Res = await node.startDiscv5()
    if startDiscv5Res.isErr():
      return err("failed to start waku discovery v5: " & startDiscv5Res.error)

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

proc startNode*(app: App): Future[AppResult[void]] {.async.} =
  return await startNode(
    app.node,
    app.conf,
    app.dynamicBootstrapNodes
  )


## Monitoring and external interfaces

proc startRestServer(app: App, address: ValidIpAddress, port: Port, conf: WakuNodeConf): AppResult[RestServerRef] =
  let server = ? newRestHttpServer(address, port)

  ## Debug REST API
  installDebugApiHandlers(server.router, app.node)

  ## Relay REST API
  if conf.relay:
    let relayCache = TopicCache.init(capacity=conf.restRelayCacheCapacity)
    installRelayApiHandlers(server.router, app.node, relayCache)

  ## Store REST API
  installStoreApiHandlers(server.router, app.node)

  server.start()
  info "Starting REST HTTP server", url = "http://" & $address & ":" & $port & "/"

  ok(server)

proc startRpcServer(app: App, address: ValidIpAddress, port: Port, conf: WakuNodeConf): AppResult[RpcHttpServer] =
  let ta = initTAddress(address, port)

  var server: RpcHttpServer
  try:
    server = newRpcHttpServer([ta])
  except CatchableError:
    return err("failed to init JSON-RPC server: " & getCurrentExceptionMsg())

  installDebugApiHandlers(app.node, server)

  if conf.relay:
    let relayMessageCache = rpc_relay_api.MessageCache.init(capacity=30)
    installRelayApiHandlers(app.node, server, relayMessageCache)
    if conf.rpcPrivate:
      installRelayPrivateApiHandlers(app.node, server, relayMessageCache)

  if conf.filternode != "":
    let filterMessageCache = rpc_filter_api.MessageCache.init(capacity=30)
    installFilterApiHandlers(app.node, server, filterMessageCache)

  installStoreApiHandlers(app.node, server)

  if conf.rpcAdmin:
    installAdminApiHandlers(app.node, server)

  server.start()
  info "RPC Server started", address=ta

  ok(server)

proc startMetricsServer(serverIp: ValidIpAddress, serverPort: Port): AppResult[MetricsHttpServerRef] =
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

proc stop*(app: App): Future[void] {.async.} =
  if app.restServer.isSome():
    await app.restServer.get().stop()

  if app.rpcServer.isSome():
    await app.rpcServer.get().stop()

  if app.metricsServer.isSome():
    await app.metricsServer.get().stop()

  if not app.node.isNil():
    await app.node.stop()
