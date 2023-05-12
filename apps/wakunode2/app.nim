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
  eth/net/nat,
  json_rpc/rpcserver,
  presto,
  metrics,
  metrics/chronos_httpserver
import
  ../../waku/common/sqlite,
  ../../waku/v2/waku_core,
  ../../waku/v2/waku_node,
  ../../waku/v2/node/waku_metrics,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ../../waku/v2/node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../../waku/v2/waku_archive,
  ../../waku/v2/waku_archive/driver/queue_driver,
  ../../waku/v2/waku_archive/driver/sqlite_driver,
  ../../waku/v2/waku_archive/driver/sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ../../waku/v2/waku_archive/retention_policy,
  ../../waku/v2/waku_archive/retention_policy/retention_policy_capacity,
  ../../waku/v2/waku_archive/retention_policy/retention_policy_time,
  ../../waku/v2/waku_dnsdisc,
  ../../waku/v2/waku_enr,
  ../../waku/v2/waku_discv5,
  ../../waku/v2/waku_peer_exchange,
  ../../waku/v2/waku_store,
  ../../waku/v2/waku_lightpush,
  ../../waku/v2/waku_filter,
  ./wakunode2_validator_signed,
  ./config
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

    rng: ref HmacDrbgContext
    peerStore: Option[WakuPeerStorage]
    archiveDriver: Option[ArchiveDriver]
    archiveRetentionPolicy: Option[RetentionPolicy]
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
  App(version: git_version, conf: conf, rng: rng, node: nil)


## SQLite database

proc setupDatabaseConnection(dbUrl: string): AppResult[Option[SqliteDatabase]] =
  ## dbUrl mimics SQLAlchemy Database URL schema
  ## See: https://docs.sqlalchemy.org/en/14/core/engines.html#database-urls
  if dbUrl == "" or dbUrl == "none":
    return ok(none(SqliteDatabase))

  let dbUrlParts = dbUrl.split("://", 1)
  let
    engine = dbUrlParts[0]
    path = dbUrlParts[1]

  let connRes = case engine
    of "sqlite":
      # SQLite engine
      # See: https://docs.sqlalchemy.org/en/14/core/engines.html#sqlite
      SqliteDatabase.new(path)

    else:
      return err("unknown database engine")

  if connRes.isErr():
    return err("failed to init database connection: " & connRes.error)

  ok(some(connRes.value))


## Peer persistence

const PeerPersistenceDbUrl = "sqlite://peers.db"

proc setupPeerStorage(): AppResult[Option[WakuPeerStorage]] =
  let db = ?setupDatabaseConnection(PeerPersistenceDbUrl)

  ?peer_store_sqlite_migrations.migrate(db.get())

  let res = WakuPeerStorage.new(db.get())
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


## Waku archive

proc gatherSqlitePageStats(db: SqliteDatabase): AppResult[(int64, int64, int64)] =
  let
    pageSize = ?db.getPageSize()
    pageCount = ?db.getPageCount()
    freelistCount = ?db.getFreelistCount()

  ok((pageSize, pageCount, freelistCount))

proc performSqliteVacuum(db: SqliteDatabase): AppResult[void] =
  ## SQLite database vacuuming
  # TODO: Run vacuuming conditionally based on database page stats
  # if (pageCount > 0 and freelistCount > 0):

  debug "starting sqlite database vacuuming"

  let resVacuum = db.vacuum()
  if resVacuum.isErr():
    return err("failed to execute vacuum: " & resVacuum.error)

  debug "finished sqlite database vacuuming"

proc setupWakuArchiveRetentionPolicy(retentionPolicy: string): AppResult[Option[RetentionPolicy]] =
  if retentionPolicy == "" or retentionPolicy == "none":
    return ok(none(RetentionPolicy))

  let rententionPolicyParts = retentionPolicy.split(":", 1)
  let
    policy = rententionPolicyParts[0]
    policyArgs = rententionPolicyParts[1]


  if policy == "time":
    var retentionTimeSeconds: int64
    try:
      retentionTimeSeconds = parseInt(policyArgs)
    except ValueError:
      return err("invalid time retention policy argument")

    let retPolicy: RetentionPolicy = TimeRetentionPolicy.init(retentionTimeSeconds)
    return ok(some(retPolicy))

  elif policy == "capacity":
    var retentionCapacity: int
    try:
      retentionCapacity = parseInt(policyArgs)
    except ValueError:
      return err("invalid capacity retention policy argument")

    let retPolicy: RetentionPolicy = CapacityRetentionPolicy.init(retentionCapacity)
    return ok(some(retPolicy))

  else:
    return err("unknown retention policy")

proc setupWakuArchiveDriver(dbUrl: string, vacuum: bool, migrate: bool): AppResult[ArchiveDriver] =
  let db = ?setupDatabaseConnection(dbUrl)

  if db.isSome():
    # SQLite vacuum
    # TODO: Run this only if the database engine is SQLite
    let (pageSize, pageCount, freelistCount) = ?gatherSqlitePageStats(db.get())
    debug "sqlite database page stats", pageSize=pageSize, pages=pageCount, freePages=freelistCount

    if vacuum and (pageCount > 0 and freelistCount > 0):
      ?performSqliteVacuum(db.get())

  # Database migration
    if migrate:
      ?archive_driver_sqlite_migrations.migrate(db.get())

  if db.isSome():
    debug "setting up sqlite waku archive driver"
    let res = SqliteDriver.new(db.get())
    if res.isErr():
      return err("failed to init sqlite archive driver: " & res.error)

    ok(res.value)

  else:
    debug "setting up in-memory waku archive driver"
    let driver = QueueDriver.new()  # Defaults to a capacity of 25.000 messages
    ok(driver)

proc setupWakuArchive*(app: var App): AppResult[void] =
  if not app.conf.store:
    return ok()

  # Message storage
  let dbUrlValidationRes = validateDbUrl(app.conf.storeMessageDbUrl)
  if dbUrlValidationRes.isErr():
    return err("failed to configure the message store database connection: " & dbUrlValidationRes.error)

  let archiveDriverRes = setupWakuArchiveDriver(dbUrlValidationRes.get(),
                                                vacuum = app.conf.storeMessageDbVacuum,
                                                migrate = app.conf.storeMessageDbMigration)
  if archiveDriverRes.isOk():
    app.archiveDriver = some(archiveDriverRes.get())
  else:
    return err("failed to configure archive driver: " & archiveDriverRes.error)

  # Message store retention policy
  let storeMessageRetentionPolicyRes = validateStoreMessageRetentionPolicy(app.conf.storeMessageRetentionPolicy)
  if storeMessageRetentionPolicyRes.isErr():
    return err("failed to configure the message retention policy: " & storeMessageRetentionPolicyRes.error)

  let archiveRetentionPolicyRes = setupWakuArchiveRetentionPolicy(storeMessageRetentionPolicyRes.get())
  if archiveRetentionPolicyRes.isOk():
    app.archiveRetentionPolicy = archiveRetentionPolicyRes.get()
  else:
    return err("failed to configure the message retention policy: " & archiveRetentionPolicyRes.error)

  # TODO: Move retention policy execution here
  # if archiveRetentionPolicy.isSome():
  #   executeMessageRetentionPolicy(node)
  #   startMessageRetentionPolicyPeriodicTask(node, interval=WakuArchiveDefaultRetentionPolicyInterval)

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

proc setupNat(natConf, clientId: string, tcpPort, udpPort: Port):
  AppResult[tuple[ip: Option[ValidIpAddress], tcpPort: Option[Port], udpPort: Option[Port]]] {.gcsafe.} =

  let strategy = case natConf.toLowerAscii():
      of "any": NatAny
      of "none": NatNone
      of "upnp": NatUpnp
      of "pmp": NatPmp
      else: NatNone

  var endpoint: tuple[ip: Option[ValidIpAddress], tcpPort: Option[Port], udpPort: Option[Port]]

  if strategy != NatNone:
    let extIp = getExternalIP(strategy)
    if extIP.isSome():
      endpoint.ip = some(ValidIpAddress.init(extIp.get()))
      # RedirectPorts in considered a gcsafety violation
      # because it obtains the address of a non-gcsafe proc?
      var extPorts: Option[(Port, Port)]
      try:
        extPorts = ({.gcsafe.}: redirectPorts(tcpPort = tcpPort,
                                              udpPort = udpPort,
                                              description = clientId))
      except CatchableError:
        # TODO: nat.nim Error: can raise an unlisted exception: Exception. Isolate here for now.
        error "unable to determine external ports"
        extPorts = none((Port, Port))

      if extPorts.isSome():
        let (extTcpPort, extUdpPort) = extPorts.get()
        endpoint.tcpPort = some(extTcpPort)
        endpoint.udpPort = some(extUdpPort)

  else: # NatNone
    if not natConf.startsWith("extip:"):
      return err("not a valid NAT mechanism: " & $natConf)

    try:
      # any required port redirection is assumed to be done by hand
      endpoint.ip = some(ValidIpAddress.init(natConf[6..^1]))
    except ValueError:
      return err("not a valid IP address: " & $natConf[6..^1])

  return ok(endpoint)

proc initNode(conf: WakuNodeConf,
              rng: ref HmacDrbgContext,
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

  let
    nodekey = if conf.nodekey.isSome():
                conf.nodekey.get()
              else:
                let nodekeyRes = crypto.PrivateKey.random(Secp256k1, rng[])
                if nodekeyRes.isErr():
                  return err("failed to generate nodekey: " & $nodekeyRes.error)
                nodekeyRes.get()


  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport for libp2p traffic.
  let udpPort = conf.tcpPort
  let natRes = setupNat(conf.nat, clientId,
                        Port(uint16(conf.tcpPort) + conf.portsShift),
                        Port(uint16(udpPort) + conf.portsShift))
  if natRes.isErr():
    return err("failed to setup NAT: " & $natRes.error)

  let (extIp, extTcpPort, _) = natRes.get()


  let
    dns4DomainName = if conf.dns4DomainName != "": some(conf.dns4DomainName)
                      else: none(string)

    discv5UdpPort = if conf.discv5Discovery: some(Port(uint16(conf.discv5UdpPort) + conf.portsShift))
                    else: none(Port)

    ## TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
    ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
    ## config, the external port is the same as the bind port.
    extPort = if (extIp.isSome() or dns4DomainName.isSome()) and extTcpPort.isNone():
                some(Port(uint16(conf.tcpPort) + conf.portsShift))
              else:
                extTcpPort
    extMultiAddrs = if (conf.extMultiAddrs.len > 0):
                      let extMultiAddrsValidationRes = validateExtMultiAddrs(conf.extMultiAddrs)
                      if extMultiAddrsValidationRes.isErr():
                        return err("invalid external multiaddress: " & extMultiAddrsValidationRes.error)
                      else:
                        extMultiAddrsValidationRes.get()
                    else:
                      @[]

    wakuFlags = CapabilitiesBitfield.init(
        lightpush = conf.lightpush,
        filter = conf.filter,
        store = conf.store,
        relay = conf.relay
      )

  var node: WakuNode

  let pStorage = if peerStore.isNone(): nil
                 else: peerStore.get()

  let rng = crypto.newRng()
  # Wrap in none because NetConfig does not have a default constructor
  # TODO: We could change bindIp in NetConfig to be something less restrictive than ValidIpAddress,
  # which doesn't allow default construction
  let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = Port(uint16(conf.tcpPort) + conf.portsShift),
      extIp = extIp,
      extPort = extPort,
      extMultiAddrs = extMultiAddrs,
      wsBindPort = Port(uint16(conf.websocketPort) + conf.portsShift),
      wsEnabled = conf.websocketSupport,
      wssEnabled = conf.websocketSecureSupport,
      dns4DomainName = dns4DomainName,
      discv5UdpPort = discv5UdpPort,
      wakuFlags = some(wakuFlags),
    )
  if netConfigRes.isErr():
    return err("failed to create net config instance: " & netConfigRes.error)

  let netConfig = netConfigRes.get()
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
        discv5Config = discv5Config,
      ))
    except CatchableError:
      return err("failed to create waku discv5 instance: " & getCurrentExceptionMsg())

  # Build waku node instance
  var builder = WakuNodeBuilder.init()
  builder.withRng(rng)
  builder.withNodeKey(nodekey)
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

  node = ? builder.build().mapErr(proc (err: string): string = "failed to create waku node instance: " & err)

  ok(node)

proc setupWakuNode*(app: var App): AppResult[void] =
  ## Waku node
  let initNodeRes = initNode(app.conf, app.rng, app.peerStore, app.dynamicBootstrapNodes)
  if initNodeRes.isErr():
    return err("failed to init node: " & initNodeRes.error)

  app.node = initNodeRes.get()
  ok()


## Mount protocols

proc setupProtocols(node: WakuNode, conf: WakuNodeConf,
                    archiveDriver: Option[ArchiveDriver],
                    archiveRetentionPolicy: Option[RetentionPolicy]): Future[AppResult[void]] {.async.} =
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

    var pubsubTopics = @[""]
    if conf.topicsDeprecated != "/waku/2/default-waku/proto":
      warn "The 'topics' parameter is deprecated. Better use the 'topic' one instead."
      if conf.topics != @["/waku/2/default-waku/proto"]:
        return err("Please don't specify 'topics' and 'topic' simultaneously. Only use the 'topic' parameter")

      # This clause (if conf.topicsDeprecated ) should disapear in >= v0.18.0
      pubsubTopics = conf.topicsDeprecated.split(" ")
    else:
      pubsubTopics = conf.topics
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
        rlnRelayMembershipIndex: some(conf.rlnRelayMembershipIndex),
        rlnRelayEthContractAddress: conf.rlnRelayEthContractAddress,
        rlnRelayEthClientAddress: conf.rlnRelayEthClientAddress,
        rlnRelayEthAccountPrivateKey: conf.rlnRelayEthAccountPrivateKey,
        rlnRelayEthAccountAddress: conf.rlnRelayEthAccountAddress,
        rlnRelayCredPath: conf.rlnRelayCredPath,
        rlnRelayCredentialsPassword: conf.rlnRelayCredentialsPassword
      )

      try:
        await node.mountRlnRelay(rlnConf)
      except CatchableError:
        return err("failed to mount waku RLN relay protocol: " & getCurrentExceptionMsg())

  if conf.store:
    # Archive setup
    let messageValidator: MessageValidator = DefaultMessageValidator()
    mountArchive(node, archiveDriver, messageValidator=some(messageValidator), retentionPolicy=archiveRetentionPolicy)

    # Store setup
    try:
      await mountStore(node)
    except CatchableError:
      return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

    # TODO: Move this to storage setup phase
    if archiveRetentionPolicy.isSome():
      executeMessageRetentionPolicy(node)
      startMessageRetentionPolicyPeriodicTask(node, interval=WakuArchiveDefaultRetentionPolicyInterval)

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
    app.archiveDriver,
    app.archiveRetentionPolicy
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

  # Start discv5 and connect to discovered nodes
  if conf.discv5Discovery:
    try:
      if not await node.startDiscv5():
        error "could not start Discovery v5"
    except CatchableError:
      return err("failed to start waku discovery v5: " & getCurrentExceptionMsg())

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
