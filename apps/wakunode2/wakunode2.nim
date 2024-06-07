when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, strutils, os, sequtils],
  stew/shims/net as stewNet,
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto
import
  ../../tools/rln_keystore_generator/rln_keystore_generator,
  ../../tools/rln_db_inspector/rln_db_inspector,
  ../../waku/common/logging,
  ../../waku/factory/external_config,
  ../../waku/factory/networks_config,
  ../../waku/factory/app,
  ../../waku/node/health_monitor,
  ../../waku/waku_api/rest/builder as rest_server_builder

logScope:
  topics = "wakunode main"

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

{.pop.}
  # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  const versionString = "version / git commit hash: " & app.git_version

  let confRes = WakuNodeConf.load(version = versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error = confRes.error
    quit(QuitFailure)

  var conf = confRes.get()

  ## Logging setup

  ## Simple change to allow create a PR

  # Adhere to NO_COLOR initiative: https://no-color.org/
  let color =
    try:
      not parseBool(os.getEnv("NO_COLOR", "false"))
    except CatchableError:
      true

  logging.setupLogLevel(conf.logLevel)
  logging.setupLogFormat(conf.logFormat, color)

  case conf.cmd
  of generateRlnKeystore:
    doRlnKeystoreGenerator(conf)
  of inspectRlnDb:
    doInspectRlnDb(conf)
  of noCommand:
    case conf.clusterId
    # cluster-id=0
    of 0:
      let clusterZeroConf = ClusterConf.ClusterZeroConf()
      conf.pubsubTopics = clusterZeroConf.pubsubTopics
      # TODO: Write some template to "merge" the configs
    # cluster-id=1 (aka The Waku Network)
    of 1:
      let twnClusterConf = ClusterConf.TheWakuNetworkConf()
      if len(conf.shards) != 0:
        conf.pubsubTopics = conf.shards.mapIt(twnClusterConf.pubsubTopics[it.uint16])
      else:
        conf.pubsubTopics = twnClusterConf.pubsubTopics

      # Override configuration
      conf.maxMessageSize = twnClusterConf.maxMessageSize
      conf.clusterId = twnClusterConf.clusterId
      conf.rlnRelay = twnClusterConf.rlnRelay
      conf.rlnRelayEthContractAddress = twnClusterConf.rlnRelayEthContractAddress
      conf.rlnRelayDynamic = twnClusterConf.rlnRelayDynamic
      conf.rlnRelayBandwidthThreshold = twnClusterConf.rlnRelayBandwidthThreshold
      conf.discv5Discovery = twnClusterConf.discv5Discovery
      conf.discv5BootstrapNodes =
        conf.discv5BootstrapNodes & twnClusterConf.discv5BootstrapNodes
      conf.rlnEpochSizeSec = twnClusterConf.rlnEpochSizeSec
      conf.rlnRelayUserMessageLimit = twnClusterConf.rlnRelayUserMessageLimit
    else:
      discard

    info "Running nwaku node", version = app.git_version
    logConfig(conf)

    # NOTE: {.threadvar.} is used to make the global variable GC safe for the closure uses it
    # It will always be called from main thread anyway.
    # Ref: https://nim-lang.org/docs/manual.html#threads-gc-safety
    var nodeHealthMonitor {.threadvar.}: WakuNodeHealthMonitor
    nodeHealthMonitor = WakuNodeHealthMonitor()
    nodeHealthMonitor.setOverallHealth(HealthStatus.INITIALIZING)

    let restServer = rest_server_builder.startRestServerEsentials(
      nodeHealthMonitor, conf
    ).valueOr:
      error "Starting esential REST server failed.", error = $error
      quit(QuitFailure)

    var wakunode2 = App.init(conf).valueOr:
      error "App initialization failed", error = error
      quit(QuitFailure)

    wakunode2.restServer = restServer

    nodeHealthMonitor.setNode(wakunode2.node)

    wakunode2.startApp().isOkOr:
      error "Starting app failed", error = error
      quit(QuitFailure)

    rest_server_builder.startRestServerProtocolSupport(
      restServer, wakunode2.node, wakunode2.wakuDiscv5, conf
    ).isOkOr:
      error "Starting protocols support REST server failed.", error = $error
      quit(QuitFailure)

    wakunode2.startMetricsServerAndLogging().isOkOr:
      error "Starting monitoring and external interfaces failed", error = error
      quit(QuitFailure)

    nodeHealthMonitor.setOverallHealth(HealthStatus.READY)

    debug "Setting up shutdown hooks"
    ## Setup shutdown hooks for this process.
    ## Stop node gracefully on shutdown.

    proc asyncStopper(node: App) {.async: (raises: [Exception]).} =
      nodeHealthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)
      await node.stop()
      quit(QuitSuccess)

    # Handle Ctrl-C SIGINT
    proc handleCtrlC() {.noconv.} =
      when defined(windows):
        # workaround for https://github.com/nim-lang/Nim/issues/4057
        setupForeignThreadGc()
      notice "Shutting down after receiving SIGINT"
      asyncSpawn asyncStopper(wakunode2)

    setControlCHook(handleCtrlC)

    # Handle SIGTERM
    when defined(posix):
      proc handleSigterm(signal: cint) {.noconv.} =
        notice "Shutting down after receiving SIGTERM"
        asyncSpawn asyncStopper(wakunode2)

      c_signal(ansi_c.SIGTERM, handleSigterm)

    # Handle SIGSEGV
    when defined(posix):
      proc handleSigsegv(signal: cint) {.noconv.} =
        # Require --debugger:native
        fatal "Shutting down after receiving SIGSEGV", stacktrace = getBacktrace()

        # Not available in -d:release mode
        writeStackTrace()

        waitFor wakunode2.stop()
        quit(QuitFailure)

      c_signal(ansi_c.SIGSEGV, handleSigsegv)

    info "Node setup complete"

    runForever()
