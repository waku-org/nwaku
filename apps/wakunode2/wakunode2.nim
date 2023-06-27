when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, strutils, os],
  stew/shims/net as stewNet,
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto
import
  ../../waku/common/logging,
  ./external_config,
  ./app

logScope:
  topics = "wakunode main"

{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  const versionString = "version / git commit hash: " & app.git_version
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


  var wakunode2 = App.init(rng, conf)

  ##############
  # Node setup #
  ##############

  debug "1/7 Setting up storage"

  ## Peer persistence
  let res1 = wakunode2.setupPeerPersistence()
  if res1.isErr():
    error "1/7 Setting up storage failed", error=res1.error
    quit(QuitFailure)

  debug "2/7 Retrieve dynamic bootstrap nodes"

  let res3 = wakunode2.setupDyamicBootstrapNodes()
  if res3.isErr():
    error "2/7 Retrieving dynamic bootstrap nodes failed", error=res3.error
    quit(QuitFailure)

  debug "3/7 Initializing node"

  let res4 = wakunode2.setupWakuNode()
  if res4.isErr():
    error "3/7 Initializing node failed", error=res4.error
    quit(QuitFailure)

  debug "4/7 Mounting protocols"

  let res5 = waitFor wakunode2.setupAndMountProtocols()
  if res5.isErr():
    error "4/7 Mounting protocols failed", error=res5.error
    quit(QuitFailure)

  debug "5/7 Starting node and mounted protocols"

  let res6 = waitFor wakunode2.startNode()
  if res6.isErr():
    error "5/7 Starting node and protocols failed", error=res6.error
    quit(QuitFailure)

  debug "6/7 Starting monitoring and external interfaces"

  let res7 = wakunode2.setupMonitoringAndExternalInterfaces()
  if res7.isErr():
    error "6/7 Starting monitoring and external interfaces failed", error=res7.error
    quit(QuitFailure)

  debug "7/7 Setting up shutdown hooks"
  ## Setup shutdown hooks for this process.
  ## Stop node gracefully on shutdown.

  proc asyncStopper(node: App) {.async.} =
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
      fatal "Shutting down after receiving SIGSEGV", stacktrace=getBacktrace()

      # Not available in -d:release mode
      writeStackTrace()

      waitFor wakunode2.stop()
      quit(QuitFailure)

    c_signal(ansi_c.SIGSEGV, handleSigsegv)

  info "Node setup complete"

  runForever()
