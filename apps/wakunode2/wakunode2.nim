when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, tables, strutils, sequtils, os],
  stew/shims/net as stewNet,
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  eth/keys,
  eth/net/nat,
  eth/p2p/discoveryv5/enr,
  libp2p/builders,
  libp2p/multihash,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/transports/wstransport,
  libp2p/nameresolving/dnsresolver
import
  ../../waku/common/sqlite,
  ../../waku/common/logging,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ../../waku/v2/node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../../waku/v2/waku_node,
  ../../waku/v2/node/waku_metrics,
  ../../waku/v2/protocol/waku_archive,
  ../../waku/v2/protocol/waku_archive/driver/queue_driver,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ../../waku/v2/protocol/waku_archive/retention_policy,
  ../../waku/v2/protocol/waku_archive/retention_policy/retention_policy_capacity,
  ../../waku/v2/protocol/waku_archive/retention_policy/retention_policy_time,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_lightpush,
  ../../waku/v2/protocol/waku_enr,
  ../../waku/v2/protocol/waku_dnsdisc,
  ../../waku/v2/protocol/waku_discv5,
  ../../waku/v2/protocol/waku_message/topics/pubsub_topic,
  ../../waku/v2/protocol/waku_peer_exchange,
  ../../waku/v2/protocol/waku_relay/validators,
  ../../waku/v2/utils/peers,
  ./config

logScope:
  topics = "wakunode main"

# Temporarily merge `app.nim` into `wakunode2.nim` until we encapsulate the
#  state and the logic in an object instance.
include ./app

{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  const versionString = "version / git commit hash: " & git_version
  let rng = crypto.newRng()

  let confRes = WakuNodeConf.load(version=versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error=confRes.error
    quit(QuitFailure)

  let conf = confRes.get()

  ## Logging setup

  # Adhere to NO_COLOR initiative: https://no-color.org/
  let color = try: not parseBool(os.getEnv("NO_COLOR", "false"))
              except CatchableError: true

  logging.setupLogLevel(conf.logLevel)
  logging.setupLogFormat(conf.logFormat, color)


  ##############
  # Node setup #
  ##############

  debug "1/7 Setting up storage"

  ## Peer persistence
  var peerStore = none(WakuPeerStorage)

  if conf.peerPersistence:
    let peerStoreRes = setupPeerStorage();
    if peerStoreRes.isOk():
      peerStore = peerStoreRes.get()
    else:
      error "failed to setup peer store", error=peerStoreRes.error
      waku_node_errors.inc(labelValues = ["init_store_failure"])

  ## Waku archive
  var archiveDriver = none(ArchiveDriver)
  var archiveRetentionPolicy = none(RetentionPolicy)

  if conf.store:
    # Message storage
    let dbUrlValidationRes = validateDbUrl(conf.storeMessageDbUrl)
    if dbUrlValidationRes.isErr():
      error "failed to configure the message store database connection", error=dbUrlValidationRes.error
      quit(QuitFailure)

    let archiveDriverRes = setupWakuArchiveDriver(dbUrlValidationRes.get(), vacuum=conf.storeMessageDbVacuum, migrate=conf.storeMessageDbMigration)
    if archiveDriverRes.isOk():
      archiveDriver = some(archiveDriverRes.get())
    else:
      error "failed to configure archive driver", error=archiveDriverRes.error
      quit(QuitFailure)

    # Message store retention policy
    let storeMessageRetentionPolicyRes = validateStoreMessageRetentionPolicy(conf.storeMessageRetentionPolicy)
    if storeMessageRetentionPolicyRes.isErr():
      error "invalid store message retention policy configuration", error=storeMessageRetentionPolicyRes.error
      quit(QuitFailure)

    let archiveRetentionPolicyRes = setupWakuArchiveRetentionPolicy(storeMessageRetentionPolicyRes.get())
    if archiveRetentionPolicyRes.isOk():
      archiveRetentionPolicy = archiveRetentionPolicyRes.get()
    else:
      error "failed to configure the message retention policy", error=archiveRetentionPolicyRes.error
      quit(QuitFailure)

    # TODO: Move retention policy execution here
    # if archiveRetentionPolicy.isSome():
    #   executeMessageRetentionPolicy(node)
    #   startMessageRetentionPolicyPeriodicTask(node, interval=WakuArchiveDefaultRetentionPolicyInterval)


  debug "2/7 Retrieve dynamic bootstrap nodes"

  var dynamicBootstrapNodes: seq[RemotePeerInfo]
  let dynamicBootstrapNodesRes = retrieveDynamicBootstrapNodes(conf.dnsDiscovery, conf.dnsDiscoveryUrl, conf.dnsDiscoveryNameServers)
  if dynamicBootstrapNodesRes.isOk():
    dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()
  else:
    warn "2/7 Retrieving dynamic bootstrap nodes failed. Continuing without dynamic bootstrap nodes.", error=dynamicBootstrapNodesRes.error

  debug "3/7 Initializing node"

  var node: WakuNode  # This is the node we're going to setup using the conf

  let initNodeRes = initNode(conf, rng, peerStore, dynamicBootstrapNodes)
  if initNodeRes.isok():
    node = initNodeRes.get()
  else:
    error "3/7 Initializing node failed. Quitting.", error=initNodeRes.error
    quit(QuitFailure)

  debug "4/7 Mounting protocols"

  let setupProtocolsRes = waitFor setupProtocols(node, conf, archiveDriver, archiveRetentionPolicy)
  if setupProtocolsRes.isErr():
    error "4/7 Mounting protocols failed. Continuing in current state.", error=setupProtocolsRes.error

  debug "5/7 Starting node and mounted protocols"

  let startNodeRes = waitFor startNode(node, conf, dynamicBootstrapNodes)
  if startNodeRes.isErr():
    error "5/7 Starting node and mounted protocols failed. Continuing in current state.", error=startNodeRes.error


  debug "6/7 Starting monitoring and external interfaces"

  if conf.rpc:
    let startRpcServerRes = startRpcServer(node, conf.rpcAddress, conf.rpcPort, conf.portsShift, conf)
    if startRpcServerRes.isErr():
      error "6/7 Starting JSON-RPC server failed. Continuing in current state.", error=startRpcServerRes.error

  if conf.rest:
    let startRestServerRes = startRestServer(node, conf.restAddress, conf.restPort, conf.portsShift, conf)
    if startRestServerRes.isErr():
      error "6/7 Starting REST server failed. Continuing in current state.", error=startRestServerRes.error

  if conf.metricsServer:
    let startMetricsServerRes = startMetricsServer(node, conf.metricsServerAddress, conf.metricsServerPort, conf.portsShift)
    if startMetricsServerRes.isErr():
      error "6/7 Starting metrics server failed. Continuing in current state.", error=startMetricsServerRes.error

  if conf.metricsLogging:
    let startMetricsLoggingRes = startMetricsLogging()
    if startMetricsLoggingRes.isErr():
      error "6/7 Starting metrics console logging failed. Continuing in current state.", error=startMetricsLoggingRes.error


  debug "7/7 Setting up shutdown hooks"
  ## Setup shutdown hooks for this process.
  ## Stop node gracefully on shutdown.

  proc asyncStopper(node: WakuNode) {.async.} =
    await node.stop()
    quit(QuitSuccess)

  # Handle Ctrl-C SIGINT
  proc handleCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    notice "Shutting down after receiving SIGINT"
    asyncSpawn asyncStopper(node)

  setControlCHook(handleCtrlC)

  # Handle SIGTERM
  when defined(posix):
    proc handleSigterm(signal: cint) {.noconv.} =
      notice "Shutting down after receiving SIGTERM"
      asyncSpawn asyncStopper(node)

    c_signal(ansi_c.SIGTERM, handleSigterm)

  # Handle SIGSEGV
  when defined(posix):
    proc handleSigsegv(signal: cint) {.noconv.} =
      # Require --debugger:native
      fatal "Shutting down after receiving SIGSEGV", stacktrace=getBacktrace()

      # Not available in -d:release mode
      writeStackTrace()

      waitFor node.stop()
      quit(QuitFailure)

    c_signal(ansi_c.SIGSEGV, handleSigsegv)

  info "Node setup complete"

  runForever()
