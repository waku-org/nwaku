{.push raises: [].}

import
  std/[options, strutils, os, sequtils, net],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto,
  confutils

import
  waku/[
    common/enr,
    common/logging,
    factory/waku,
    factory/external_config,
    waku_node,
    node/health_monitor,
    node/waku_metrics,
    node/peer_manager,
    waku_api/rest/builder as rest_server_builder,
    waku_lightpush/common,
    waku_filter_v2,
    waku_peer_exchange/protocol,
    waku_core/peers,
  ],
  ./tester_config,
  ./lightpush_publisher,
  ./filter_subscriber,
  ./diagnose_connections

logScope:
  topics = "liteprotocoltester main"

proc logConfig(conf: LiteProtocolTesterConf) =
  info "Configuration: Lite protocol tester", conf = $conf

proc pxLookupServiceNode(
    node: WakuNode, conf: LiteProtocolTesterConf
): Future[bool] {.async.} =
  var codec = WakuLightPushCodec
  if conf.testFunc == TesterFunctionality.RECEIVER:
    codec = WakuFilterSubscribeCodec

  if node.wakuPeerExchange.isNil():
    var peerExchangeNode: RemotePeerInfo
    var enrRec: enr.Record
    if enrRec.fromURI(conf.bootstrapNode):
      info "Parsed bootstrap ENR", enrRec = $enrRec
      peerExchangeNode = enrRec.toRemotePeerInfo().valueOr:
        error "failed to parse bootstrap ENR: ", error = error
        return false
    else:
      peerExchangeNode = parsePeerInfo(conf.bootstrapNode).valueOr:
        error "failed to parse node waku peer-exchange peerId", error = error
        return false

    node.peerManager.addServicePeer(peerExchangeNode, WakuPeerExchangeCodec)

    try:
      await node.mountPeerExchange(some(conf.clusterId))
    except CatchableError:
      error "failed to mount waku peer-exchange protocol: ",
        error = getCurrentExceptionMsg()
      return false

  var trialCount = 5
  while trialCount > 0:
    let peerOpt = node.peerManager.selectPeer(codec)
    if peerOpt.isSome():
      info "Found service peer for codec", codec = codec, peer = peerOpt.get()
      let peerForCodec = node.peerManager.peerStore.getPeersByProtocol(codec)
      info "Having number of peers for codec", codec = codec, count = peerForCodec.len()
      info "All peers we have", peers = node.peerManager.peerStore.peers()
      return true

    let futPeers = node.fetchPeerExchangePeers(5)
    if not await futPeers.withTimeout(10.seconds):
      notice "Cannot get peers from PX", round = 5 - trialCount
    else:
      if futPeers.value().isErr():
        info "PeerExchange reported error", error = futPeers.value().error
        return false

    await sleepAsync(5.seconds)
    trialCount -= 1

  return false

{.pop.}
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  const versionString = "version / git commit hash: " & waku.git_version

  let confRes = LiteProtocolTesterConf.load(version = versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error = confRes.error
    quit(QuitFailure)

  var conf = confRes.get()

  ## Logging setup
  logging.setupLog(conf.logLevel, conf.logFormat)

  info "Running Lite Protocol Tester node", version = waku.git_version
  logConfig(conf)

  ##Prepare Waku configuration
  ## - load from config file
  ## - override according to tester functionality
  ##

  var wakuConf: WakuNodeConf

  if conf.configFile.isSome():
    try:
      var configFile {.threadvar.}: InputFile
      configFile = conf.configFile.get()
      wakuConf = WakuNodeConf.load(
        version = versionString,
        printUsage = false,
        secondarySources = proc(
            wnconf: WakuNodeConf, sources: auto
        ) {.gcsafe, raises: [ConfigurationError].} =
          echo "Loading secondary configuration file into WakuNodeConf"
          sources.addConfigFile(Toml, configFile)
        ,
      )
    except CatchableError:
      error "Loading Waku configuration failed", error = getCurrentExceptionMsg()
      quit(QuitFailure)

  wakuConf.logLevel = conf.logLevel
  wakuConf.logFormat = conf.logFormat
  wakuConf.staticnodes = @[conf.serviceNode]
  wakuConf.nat = conf.nat
  wakuConf.maxConnections = 500
  wakuConf.restAddress = conf.restAddress
  wakuConf.restPort = conf.restPort
  wakuConf.restAllowOrigin = conf.restAllowOrigin

  wakuConf.dnsAddrs = true
  wakuConf.dnsAddrsNameServers = @[parseIpAddress("8.8.8.8"), parseIpAddress("1.1.1.1")]

  wakuConf.pubsubTopics = conf.pubsubTopics
  wakuConf.contentTopics = conf.contentTopics
  wakuConf.clusterId = conf.clusterId
  ## TODO: Depending on the tester needs we might extend here with shards, clusterId, etc...

  wakuConf.metricsServer = true
  wakuConf.metricsServerAddress = parseIpAddress("0.0.0.0")
  wakuConf.metricsServerPort = 8003

  if conf.testFunc == TesterFunctionality.SENDER:
    wakuConf.lightpushnode = conf.serviceNode
  else:
    wakuConf.filterNode = conf.serviceNode

  var lookForServiceNode = false
  if conf.serviceNode.len == 0 and conf.bootstrapNode.len > 0:
    # If bootstrap option is chosen we expect our clients will not mounted
    # so we will mount PeerExchange to gather possible service peers, if got some
    # we will mount the client protocols afterward.
    wakuConf.peerExchange = false
    # wakuConf.peerExchangeNode = conf.bootstrapNode
    lookForServiceNode = true

  wakuConf.relay = false
  wakuConf.filter = false
  wakuConf.lightpush = false
  wakuConf.store = false

  wakuConf.rest = false

  # NOTE: {.threadvar.} is used to make the global variable GC safe for the closure uses it
  # It will always be called from main thread anyway.
  # Ref: https://nim-lang.org/docs/manual.html#threads-gc-safety
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

  if lookForServiceNode:
    let futForServiceNode = pxLookupServiceNode(wakuApp.node, conf)
    if not waitFor futForServiceNode.withTimeout(2.minutes):
      error "Service node not found in time via PX"
      quit(QuitFailure)

    if not futForServiceNode.value():
      error "Service node for test not found via PX"
      quit(QuitFailure)

  if conf.testFunc == TesterFunctionality.SENDER:
    waitFor startPeriodicPeerDiagnostic(wakuApp.node.peerManager, WakuLightPushCodec)
    setupAndPublish(wakuApp.node, conf)
  else:
    waitFor startPeriodicPeerDiagnostic(
      wakuApp.node.peerManager, WakuFilterSubscribeCodec
    )
    setupAndSubscribe(wakuApp.node, conf)

  runForever()
