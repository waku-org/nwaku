{.push raises: [].}

import
  std/[options, strutils, sequtils, net],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto
import
  ../../tools/rln_keystore_generator/rln_keystore_generator,
  ../../tools/rln_db_inspector/rln_db_inspector,
  waku/[
    common/logging,
    factory/external_config,
    factory/waku,
    node/health_monitor,
    node/waku_metrics,
    waku_api/rest/builder as rest_server_builder,
  ]

logScope:
  topics = "wakunode main"

const git_version* {.strdefine.} = "n/a"

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

  const versionString = "version / git commit hash: " & waku.git_version

  var wakuNodeConf = WakuNodeConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = error
    quit(QuitFailure)

  ## Also called within Waku.new. The call to startRestServerEssentials needs the following line
  logging.setupLog(wakuNodeConf.logLevel, wakuNodeConf.logFormat)

  case wakuNodeConf.cmd
  of generateRlnKeystore:
    let conf = wakuNodeConf.toKeystoreGeneratorConf()
    doRlnKeystoreGenerator(conf)
  of inspectRlnDb:
    let conf = wakuNodeConf.toInspectRlnDbConf()
    doInspectRlnDb(conf)
  of noCommand:
    # NOTE: {.threadvar.} is used to make the global variable GC safe for the closure uses it
    # It will always be called from main thread anyway.
    # Ref: https://nim-lang.org/docs/manual.html#threads-gc-safety
    var nodeHealthMonitor {.threadvar.}: WakuNodeHealthMonitor
    nodeHealthMonitor = WakuNodeHealthMonitor()
    nodeHealthMonitor.setOverallHealth(HealthStatus.INITIALIZING)

    let conf = wakuNodeConf.toWakuConf().valueOr:
      error "Waku configuration failed", error = error
      quit(QuitFailure)

    var restServer: WakuRestServerRef = nil

    if conf.restServerConf.isSome():
      restServer = rest_server_builder.startRestServerEssentials(
        nodeHealthMonitor, conf.restServerConf.get(), conf.portsShift
      ).valueOr:
        error "Starting essential REST server failed.", error = $error
        quit(QuitFailure)

    var waku = Waku.new(conf).valueOr:
      error "Waku initialization failed", error = error
      quit(QuitFailure)

    waku.restServer = restServer

    nodeHealthMonitor.setNode(waku.node)

    (waitFor startWaku(addr waku)).isOkOr:
      error "Starting waku failed", error = error
      quit(QuitFailure)

    if conf.restServerConf.isSome():
      rest_server_builder.startRestServerProtocolSupport(
        restServer,
        waku.node,
        waku.wakuDiscv5,
        conf.restServerConf.get(),
        conf.relay,
        conf.lightPush,
        conf.clusterId,
        conf.shards,
        conf.contentTopics,
      ).isOkOr:
        error "Starting protocols support REST server failed.", error = $error
        quit(QuitFailure)

    if conf.metricsServerConf.isSome():
      waku.metricsServer = waku_metrics.startMetricsServerAndLogging(
        conf.metricsServerConf.get(), conf.portsShift
      ).valueOr:
        error "Starting monitoring and external interfaces failed", error = error
        quit(QuitFailure)

    nodeHealthMonitor.setOverallHealth(HealthStatus.READY)

    debug "Setting up shutdown hooks"
    ## Setup shutdown hooks for this process.
    ## Stop node gracefully on shutdown.

    proc asyncStopper(node: Waku) {.async: (raises: [Exception]).} =
      nodeHealthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)
      await node.stop()
      quit(QuitSuccess)

    # Handle Ctrl-C SIGINT
    proc handleCtrlC() {.noconv.} =
      when defined(windows):
        # workaround for https://github.com/nim-lang/Nim/issues/4057
        setupForeignThreadGc()
      notice "Shutting down after receiving SIGINT"
      asyncSpawn asyncStopper(waku)

    setControlCHook(handleCtrlC)

    # Handle SIGTERM
    when defined(posix):
      proc handleSigterm(signal: cint) {.noconv.} =
        notice "Shutting down after receiving SIGTERM"
        asyncSpawn asyncStopper(waku)

      c_signal(ansi_c.SIGTERM, handleSigterm)

    # Handle SIGSEGV
    when defined(posix):
      proc handleSigsegv(signal: cint) {.noconv.} =
        # Require --debugger:native
        fatal "Shutting down after receiving SIGSEGV", stacktrace = getBacktrace()

        # Not available in -d:release mode
        writeStackTrace()

        waitFor waku.stop()
        quit(QuitFailure)

      c_signal(ansi_c.SIGSEGV, handleSigsegv)

    info "Node setup complete"

    runForever()
