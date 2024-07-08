{.push raises: [].}

import
  std/[options, strutils, os, sequtils, net],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto,
  confutils,
  results

import
  ./sonda_config,
  ../../waku/common/logging,
  ../../waku/factory/waku,
  ../../waku/factory/external_config,
  ../../waku/node/health_monitor,
  ../../waku/waku_api/rest/builder as rest_server_builder,
  ../../waku/node/waku_metrics

logScope:
  topics = "sonda main"

proc logConfig(conf: SondaConf) =
  info "Configuration: Sonda", conf = $conf

{.pop.}
when isMainModule:
  const versionString = "version / git commit hash: " & waku.git_version

  let confRes = SondaConf.loadConfig(version = versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error = confRes.error
    quit(QuitFailure)

  var conf = confRes.get()

  ## Logging setup
  logging.setupLog(conf.logLevel, conf.logFormat)

  info "Running Sonda", version = waku.git_version
  logConfig(conf)

  var wakuConf = defaultWakuNodeConf().valueOr:
    error "failed retrieving default node configuration", error = confRes.error
    quit(QuitFailure)

  wakuConf.logLevel = conf.logLevel
  wakuConf.logFormat = conf.logFormat
  wakuConf.clusterId = conf.clusterId
  wakuConf.shards = @[conf.shard]
  wakuConf.staticnodes = conf.storenodes # connect directly to store nodes to query

  var nodeHealthMonitor {.threadvar.}: WakuNodeHealthMonitor
  nodeHealthMonitor = WakuNodeHealthMonitor()
  nodeHealthMonitor.setOverallHealth(HealthStatus.INITIALIZING)

  let restServer = rest_server_builder.startRestServerEsentials(
    nodeHealthMonitor, wakuConf
  ).valueOr:
    error "Starting esential REST server failed.", error = $error
    quit(QuitFailure)

  var wakuApp = Waku.init(wakuConf).valueOr:
    error "Waku initialization failed", error = error
    quit(QuitFailure)

  wakuApp.restServer = restServer

  nodeHealthMonitor.setNode(wakuApp.node)

  (waitFor startWaku(addr wakuApp)).isOkOr:
    error "Starting waku failed", error = error
    quit(QuitFailure)

  rest_server_builder.startRestServerProtocolSupport(
    restServer, wakuApp.node, wakuApp.wakuDiscv5, wakuConf
  ).isOkOr:
    error "Starting protocols support REST server failed.", error = $error
    quit(QuitFailure)

  wakuApp.metricsServer = waku_metrics.startMetricsServerAndLogging(wakuConf).valueOr:
    error "Starting monitoring and external interfaces failed", error = error
    quit(QuitFailure)

  nodeHealthMonitor.setOverallHealth(HealthStatus.READY)

  debug "Setting up shutdown hooks"
  ## Setup shutdown hooks for this process.
  ## Stop node gracefully on shutdown.

  proc asyncStopper(wakuApp: Waku) {.async: (raises: [Exception]).} =
    nodeHealthMonitor.setOverallHealth(HealthStatus.SHUTTING_DOWN)
    await wakuApp.stop()
    quit(QuitSuccess)

  # Handle Ctrl-C SIGINT
  proc handleCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    notice "Shutting down after receiving SIGINT"
    asyncSpawn asyncStopper(wakuApp)

  setControlCHook(handleCtrlC)

  # Handle SIGTERM
  when defined(posix):
    proc handleSigterm(signal: cint) {.noconv.} =
      notice "Shutting down after receiving SIGTERM"
      asyncSpawn asyncStopper(wakuApp)

    c_signal(ansi_c.SIGTERM, handleSigterm)

  # Handle SIGSEGV
  when defined(posix):
    proc handleSigsegv(signal: cint) {.noconv.} =
      # Require --debugger:native
      fatal "Shutting down after receiving SIGSEGV", stacktrace = getBacktrace()

      # Not available in -d:release mode
      writeStackTrace()

      waitFor wakuApp.stop()
      quit(QuitFailure)

    c_signal(ansi_c.SIGSEGV, handleSigsegv)

  info "Node setup complete"

  runForever()
