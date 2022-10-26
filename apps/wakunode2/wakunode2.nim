{.push raises: [Defect].}

import
  std/[options, tables, strutils, sequtils, os],
  stew/shims/net as stewNet,
  chronicles, 
  chronos,
  metrics,
  confutils, 
  toml_serialization,
  system/ansi_c,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/[builders, multihash],
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/[gossipsub, rpc/messages],
  libp2p/transports/[transport, wstransport],
  libp2p/nameresolving/dnsresolver
import
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_peer_exchange,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/dnsdisc/waku_dnsdisc,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/node/storage/peer/waku_peer_storage,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/node/storage/message/dual_message_store,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/storage/message/message_retention_policy_capacity,
  ../../waku/v2/node/storage/message/message_retention_policy_time,
  ../../waku/v2/node/[wakuswitch, waku_node, waku_metrics],
  ../../waku/v2/utils/[peers, wakuenr],
  ../../waku/common/utils/nat,
  ./wakunode2_setup_rest,
  ./wakunode2_setup_rpc,
  ./wakunode2_setup_sql_migrations,
  ./config

when defined(rln) or defined(rlnzerokit):
  import
    ../../waku/v2/protocol/waku_rln_relay/waku_rln_relay_types,
    ../../waku/v2/protocol/waku_rln_relay/waku_rln_relay_utils


logScope:
  topics = "wakunode.setup"


type SetupResult[T] = Result[T, string]


proc setupStorage(conf: WakuNodeConf):
  SetupResult[tuple[pStorage: WakuPeerStorage, mStorage: MessageStore]] =

  ## Setup a SQLite Database for a wakunode based on a supplied
  ## configuration file and perform all necessary migration.
  ## 
  ## If config allows, return peer storage and message store
  ## for use elsewhere.
  
  var
    sqliteDatabase: SqliteDatabase
    storeTuple: tuple[pStorage: WakuPeerStorage, mStorage: MessageStore]

  # Setup database connection
  if conf.dbPath != "":
    let dbRes = SqliteDatabase.init(conf.dbPath)
    if dbRes.isErr():
      warn "failed to init database connection", err = dbRes.error
      waku_node_errors.inc(labelValues = ["init_db_failure"])
      return err("failed to init database connection")
    else:
      sqliteDatabase = dbRes.value


  if not sqliteDatabase.isNil():
    ## Database vacuuming
    # TODO: Wrap and move this logic to the appropriate module
    let 
      pageSize = ?sqliteDatabase.getPageSize()
      pageCount = ?sqliteDatabase.getPageCount()
      freelistCount = ?sqliteDatabase.getFreelistCount()

    debug "sqlite database page stats", pageSize=pageSize, pages=pageCount, freePages=freelistCount

    # TODO: Run vacuuming conditionally based on database page stats
    if conf.dbVacuum and (pageCount > 0 and freelistCount > 0):
      debug "starting sqlite database vacuuming"

      let resVacuum = sqliteDatabase.vacuum()
      if resVacuum.isErr():
        return err("failed to execute vacuum: " & resVacuum.error())

      debug "finished sqlite database vacuuming"

    sqliteDatabase.runMigrations(conf) 


  if conf.persistPeers:
    let res = WakuPeerStorage.new(sqliteDatabase)
    if res.isErr():
      warn "failed to init peer store", err = res.error
      waku_node_errors.inc(labelValues = ["init_store_failure"])
    else:
      storeTuple.pStorage = res.value

  if conf.persistMessages:
    if conf.sqliteStore:
      debug "setting up sqlite-only store"
      let res = SqliteStore.init(sqliteDatabase)
      if res.isErr():
        warn "failed to init message store", err = res.error
        waku_node_errors.inc(labelValues = ["init_store_failure"])
      else:
        storeTuple.mStorage = res.value
    elif not sqliteDatabase.isNil():
      debug "setting up dual message store"
      let res = DualMessageStore.init(sqliteDatabase, conf.storeCapacity)
      if res.isErr():
        warn "failed to init message store", err = res.error
        waku_node_errors.inc(labelValues = ["init_store_failure"])
      else:
        storeTuple.mStorage = res.value
    else:
      debug "setting up in-memory store"
      storeTuple.mStorage = StoreQueueRef.new(conf.storeCapacity)

  ok(storeTuple)

proc retrieveDynamicBootstrapNodes(conf: WakuNodeConf): SetupResult[seq[RemotePeerInfo]] =
  
  if conf.dnsDiscovery and conf.dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url=conf.dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in conf.dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain=domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(conf.dnsDiscoveryUrl,
                                                  resolver)
    if wakuDnsDiscovery.isOk:
      return wakuDnsDiscovery.get().findPeers()
        .mapErr(proc (e: cstring): string = $e)
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

proc initNode(conf: WakuNodeConf,
              pStorage: WakuPeerStorage = nil,
              dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[]): SetupResult[WakuNode] =
  
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
    ## `udpPort` is only supplied to satisfy underlying APIs but is not
    ## actually a supported transport for libp2p traffic.
    udpPort = conf.tcpPort
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat,
                                              clientId,
                                              Port(uint16(conf.tcpPort) + conf.portsShift),
                                              Port(uint16(udpPort) + conf.portsShift))

    dns4DomainName = if conf.dns4DomainName != "": some(conf.dns4DomainName)
                      else: none(string)
    
    discv5UdpPort = if conf.discv5Discovery: some(Port(uint16(conf.discv5UdpPort) + conf.portsShift))
                    else: none(Port)

    ## @TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
    ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
    ## config, the external port is the same as the bind port.
    extPort = if (extIp.isSome() or dns4DomainName.isSome()) and extTcpPort.isNone():
                some(Port(uint16(conf.tcpPort) + conf.portsShift))
              else:
                extTcpPort
    
    wakuFlags = initWakuFlags(conf.lightpush,
                              conf.filter,
                              conf.store,
                              conf.relay)

  var node: WakuNode
  try:
    node = WakuNode.new(conf.nodekey,
                        conf.listenAddress, Port(uint16(conf.tcpPort) + conf.portsShift), 
                        extIp, extPort,
                        pStorage,
                        conf.maxConnections.int,
                        Port(uint16(conf.websocketPort) + conf.portsShift),
                        conf.websocketSupport,
                        conf.websocketSecureSupport,
                        conf.websocketSecureKeyPath,
                        conf.websocketSecureCertPath,
                        some(wakuFlags),
                        dnsResolver,
                        conf.relayPeerExchange, # We send our own signed peer record when peer exchange enabled
                        dns4DomainName,
                        discv5UdpPort
                        )
  except:
    return err("failed to create waku node instance: " & getCurrentExceptionMsg())
  
  if conf.discv5Discovery:
    let
      discoveryConfig = DiscoveryConfig.init(
        conf.discv5TableIpLimit, conf.discv5BucketIpLimit, conf.discv5BitsPerHop)

    # select dynamic bootstrap nodes that have an ENR containing a udp port.
    # Discv5 only supports UDP https://github.com/ethereum/devp2p/blob/master/discv5/discv5-theory.md)
    var discv5BootstrapEnrs: seq[enr.Record]
    for n in dynamicBootstrapNodes:
      if n.enr.isSome():
        let
          enr = n.enr.get()
          tenrRes = enr.toTypedRecord()
        if tenrRes.isOk() and (tenrRes.get().udp.isSome() or tenrRes.get().udp6.isSome()):
          discv5BootstrapEnrs.add(enr)
  
    # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
    for enrUri in conf.discv5BootstrapNodes:
      addBootstrapNode(enrUri, discv5BootstrapEnrs)

    node.wakuDiscv5 = WakuDiscoveryV5.new(
      extIP, extPort, discv5UdpPort,
      conf.listenAddress,
      discv5UdpPort.get(),
      discv5BootstrapEnrs,
      conf.discv5EnrAutoUpdate,
      keys.PrivateKey(conf.nodekey.skkey),
      wakuFlags,
      [], # Empty enr fields, for now
      node.rng,
      discoveryConfig
    )
  
  ok(node)

proc setupProtocols(node: WakuNode, conf: WakuNodeConf, mStorage: MessageStore): Future[SetupResult[void]] {.async.} =
  ## Setup configured protocols on an existing Waku v2 node.
  ## Optionally include persistent message storage.
  ## No protocols are started yet.
  
  # Mount relay on all nodes
  var peerExchangeHandler = none(RoutingRecordsHandler)
  if conf.relayPeerExchange:
    proc handlePeerExchange(peer: PeerId, topic: string,
                            peers: seq[RoutingRecordsPair]) {.gcsafe, raises: [Defect].} =
      ## Handle peers received via gossipsub peer exchange
      # TODO: Only consider peers on pubsub topics we subscribe to
      let exchangedPeers = peers.filterIt(it.record.isSome()) # only peers with populated records
                                .mapIt(toRemotePeerInfo(it.record.get()))
      
      debug "connecting to exchanged peers", src=peer, topic=topic, numPeers=exchangedPeers.len

      # asyncSpawn, as we don't want to block here
      asyncSpawn node.connectToNodes(exchangedPeers, "peer exchange")
  
    peerExchangeHandler = some(handlePeerExchange)

  if conf.relay:
    try:
      let pubsubTopics = conf.topics.split(" ")
      await mountRelay(node, pubsubTopics, peerExchangeHandler = peerExchangeHandler) 
    except:
      return err("failed to mount waku relay protocol: " & getCurrentExceptionMsg())

  
  # Keepalive mounted on all nodes
  try:
    await mountLibp2pPing(node)
  except:
    return err("failed to mount libp2p ping protocol: " & getCurrentExceptionMsg())
  
  when defined(rln) or defined(rlnzerokit): 
    if conf.rlnRelay:
      try: 
        let res = node.mountRlnRelay(conf)
        if res.isErr():
          return err("failed to mount waku RLN relay protocol: " & res.error)
      except:
        return err("failed to mount waku RLN relay protocol: " & getCurrentExceptionMsg())
  
  if conf.swap:
    try:
      await mountSwap(node)
      # TODO: Set swap peer, for now should be same as store peer
    except:
      return err("failed to mount waku swap protocol: " & getCurrentExceptionMsg())

  # Store setup
  if (conf.storenode != "") or (conf.store):
    let retentionPolicy = if conf.sqliteStore: TimeRetentionPolicy.init(conf.sqliteRetentionTime)
                          else: CapacityRetentionPolicy.init(conf.storeCapacity)

    try:
      await mountStore(node, mStorage, retentionPolicy=some(retentionPolicy))
    except:
      return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

    executeMessageRetentionPolicy(node)
    startMessageRetentionPolicyPeriodicTask(node, interval=MessageStoreDefaultRetentionPolicyInterval)

    if conf.storenode != "":
      try:
        setStorePeer(node, conf.storenode)
      except:
        return err("failed to set node waku store peer: " & getCurrentExceptionMsg())

  # NOTE Must be mounted after relay
  if (conf.lightpushnode != "") or (conf.lightpush):
    try:
      await mountLightPush(node)
    except:
      return err("failed to mount waku lightpush protocol: " & getCurrentExceptionMsg())

    if conf.lightpushnode != "":
      try:
        setLightPushPeer(node, conf.lightpushnode)
      except:
        return err("failed to set node waku lightpush peer: " & getCurrentExceptionMsg())
  
  # Filter setup. NOTE Must be mounted after relay
  if (conf.filternode != "") or (conf.filter):
    try:
      await mountFilter(node, filterTimeout = chronos.seconds(conf.filterTimeout))
    except:
      return err("failed to mount waku filter protocol: " & getCurrentExceptionMsg())

    if conf.filternode != "":
      try:
        setFilterPeer(node, conf.filternode)
      except:
        return err("failed to set node waku filter peer: " & getCurrentExceptionMsg())
  
  # waku peer exchange setup
  if (conf.peerExchangeNode != "") or (conf.peerExchange):
    try:
      await mountWakuPeerExchange(node)
    except:
      return err("failed to mount waku peer-exchange protocol: " & getCurrentExceptionMsg())

    asyncSpawn runPeerExchangeDiscv5Loop(node.wakuPeerExchange)

    if conf.peerExchangeNode != "":
      try:
        setPeerExchangePeer(node, conf.peerExchangeNode)
      except:
        return err("failed to set node waku peer-exchange peer: " & getCurrentExceptionMsg())

  return ok()

proc startNode(node: WakuNode, conf: WakuNodeConf,
  dynamicBootstrapNodes: seq[RemotePeerInfo] = @[]): Future[SetupResult[void]] {.async.} =
  ## Start a configured node and all mounted protocols.
  ## Resume history, connect to static nodes and start
  ## keep-alive, if configured.
  
  # Start Waku v2 node
  try:
    await node.start()
  except:
    return err("failed to start waku node: " & getCurrentExceptionMsg())

  # Start discv5 and connect to discovered nodes
  if conf.discv5Discovery:
    try:
      if not await node.startDiscv5():
        error "could not start Discovery v5"
    except:
      return err("failed to start waku discovery v5: " & getCurrentExceptionMsg())


  # Resume historical messages, this has to be called after the node has been started
  if conf.store and conf.persistMessages:
    try:
      await node.resume()
    except:
      return err("failed to resume messages history: " & getCurrentExceptionMsg())
  
  # Connect to configured static nodes
  if conf.staticnodes.len > 0:
    try:
      await connectToNodes(node, conf.staticnodes, "static")
    except:
      return err("failed to connect to static nodes: " & getCurrentExceptionMsg())
  
  if dynamicBootstrapNodes.len > 0:
    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(node, dynamicBootstrapNodes, "dynamic bootstrap")
    except:
      return err("failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg())
    

  # retrieve and connect to peer exchange peers
  if conf.peerExchangeNode != "":
    info "Retrieving peer info via peer exchange protocol"
    let desiredOutDegree = node.wakuRelay.parameters.d.uint64()
    try:
      discard await node.wakuPeerExchange.request(desiredOutDegree)
    except:
      return err("failed to retrieve peer info via peer exchange protocol: " & getCurrentExceptionMsg())

  # Start keepalive, if enabled
  if conf.keepAlive:
    node.startKeepalive()
  
  return ok()

proc startExternal(node: WakuNode, conf: WakuNodeConf): SetupResult[void] =
  ## Start configured external interfaces and monitoring tools
  ## on a Waku v2 node, including the RPC API, REST API and metrics
  ## monitoring ports.
  
  if conf.rpc:
    try:
      startRpcServer(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift), conf)
    except:
      return err("failed to start the json-rpc server: " & getCurrentExceptionMsg())
  
  if conf.rest:
    startRestServer(node, conf.restAddress, Port(conf.restPort + conf.portsShift), conf)

  if conf.metricsLogging:
    startMetricsLog()

  if conf.metricsServer:
    startMetricsServer(conf.metricsServerAddress,
      Port(conf.metricsServerPort + conf.portsShift))
  
  ok()


{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks
  
  {.push warning[ProveInit]: off.}
  let conf = try:
    WakuNodeConf.load(
      secondarySources = proc (conf: WakuNodeConf, sources: auto) =
        if conf.configFile.isSome:
          sources.addConfigFile(Toml, conf.configFile.get)
    )
  except CatchableError:
    error "Failure while loading the configuration: \n", error=getCurrentExceptionMsg()
    quit 1 # if we don't leave here, the initialization of conf does not work in the success case
  {.pop.}

  # if called with --version, print the version and quit
  if conf.version:
    echo "version / git commit hash: ", git_version
    quit(QuitSuccess)

  # set log level
  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)
  
  var
    node: WakuNode  # This is the node we're going to setup using the conf

  ##############
  # Node setup #
  ##############
  
  debug "1/7 Setting up storage"
  
  var
    pStorage: WakuPeerStorage
    mStorage: MessageStore
  
  let setupStorageRes = setupStorage(conf)
  if setupStorageRes.isErr():
    error "1/7 Setting up storage failed. Continuing without storage.", error=setupStorageRes.error
  else:
    (pStorage, mStorage) = setupStorageRes.get()

  debug "2/7 Retrieve dynamic bootstrap nodes"
  
  var dynamicBootstrapNodes: seq[RemotePeerInfo]
  let dynamicBootstrapNodesRes = retrieveDynamicBootstrapNodes(conf)
  if dynamicBootstrapNodesRes.isErr():
    warn "2/7 Retrieving dynamic bootstrap nodes failed. Continuing without dynamic bootstrap nodes.", error=dynamicBootstrapNodesRes.error
  else:
    dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

  debug "3/7 Initializing node"

  let initNodeRes = initNode(conf, pStorage, dynamicBootstrapNodes)
  if initNodeRes.isErr():
    error "3/7 Initializing node failed. Quitting.", error=initNodeRes.error
    quit(QuitFailure)
  else:
    node = initNodeRes.get()

  debug "4/7 Mounting protocols"

  let setupProtocolsRes = waitFor setupProtocols(node, conf, mStorage)
  if setupProtocolsRes.isErr():
    error "4/7 Mounting protocols failed. Continuing in current state.", error=setupProtocolsRes.error

  debug "5/7 Starting node and mounted protocols"
  
  let startNodeRes = waitFor startNode(node, conf, dynamicBootstrapNodes)
  if startNodeRes.isErr():
    error "5/7 Starting node and mounted protocols failed. Continuing in current state.", error=startNodeRes.error

  debug "6/7 Starting monitoring and external interfaces"

  let startExternalRes = startExternal(node, conf)
  if startExternalRes.isErr():
    error "6/7 Starting monitoring and external interfaces failed. Continuing in current state.", error=startExternalRes.error

  debug "7/7 Setting up shutdown hooks"

  # 7/7 Setup graceful shutdown hooks
  ## Setup shutdown hooks for this process.
  ## Stop node gracefully on shutdown.
  
  # Handle Ctrl-C SIGINT
  proc handleCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    info "Shutting down after receiving SIGINT"
    waitFor node.stop()
    quit(QuitSuccess)
  
  setControlCHook(handleCtrlC)

  # Handle SIGTERM
  when defined(posix):
    proc handleSigterm(signal: cint) {.noconv.} =
      info "Shutting down after receiving SIGTERM"
      waitFor node.stop()
      quit(QuitSuccess)
    
    c_signal(ansi_c.SIGTERM, handleSigterm)
  
  info "Node setup complete"

  runForever()
