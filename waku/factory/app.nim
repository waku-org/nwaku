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
  presto,
  metrics,
  metrics/chronos_httpserver
import
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/node/waku_metrics,
  ../../waku/node/peer_manager,
  ../../waku/node/health_monitor,
  ../../waku/waku_api/message_cache,
  ../../waku/waku_api/handlers,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/debug/handlers as rest_debug_api,
  ../../waku/waku_api/rest/relay/handlers as rest_relay_api,
  ../../waku/waku_api/rest/filter/handlers as rest_filter_api,
  ../../waku/waku_api/rest/lightpush/handlers as rest_lightpush_api,
  ../../waku/waku_api/rest/store/handlers as rest_store_api,
  ../../waku/waku_api/rest/health/handlers as rest_health_api,
  ../../waku/waku_api/rest/admin/handlers as rest_admin_api,
  ../../waku/waku_archive,
  ../../waku/discovery/waku_dnsdisc,
  ../../waku/discovery/waku_discv5,
  ../../waku/waku_enr/sharding,
  ../../waku/waku_rln_relay,
  ../../waku/waku_store,
  ../../waku/waku_filter_v2,
  ../../waku/factory/node_factory,
  ../../waku/factory/internal_config,
  ../../waku/factory/external_config

logScope:
  topics = "wakunode app"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

type
  App* = object
    version: string
    conf: WakuNodeConf
    rng: ref HmacDrbgContext
    key: crypto.PrivateKey

    wakuDiscv5*: Option[WakuDiscoveryV5]
    dynamicBootstrapNodes: seq[RemotePeerInfo]

    node: WakuNode

    restServer*: WakuRestServerRef
    metricsServer: Option[MetricsHttpServerRef]

  AppResult*[T] = Result[T, string]

func node*(app: App): WakuNode =
  app.node

func version*(app: App): string =
  app.version

## Retrieve dynamic bootstrap nodes (DNS discovery)

proc retrieveDynamicBootstrapNodes*(
    dnsDiscovery: bool, dnsDiscoveryUrl: string, dnsDiscoveryNameServers: seq[IpAddress]
): Result[seq[RemotePeerInfo], string] =
  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url = dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain = domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers().mapErr(
          proc(e: cstring): string =
            $e
        )
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

## Initialisation

proc init*(T: type App, conf: WakuNodeConf): Result[App, string] =
  var confCopy = conf
  let rng = crypto.newRng()

  if not confCopy.nodekey.isSome():
    let keyRes = crypto.PrivateKey.random(Secp256k1, rng[])
    if keyRes.isErr():
      error "Failed to generate key", error = $keyRes.error
      return err("Failed to generate key: " & $keyRes.error)
    confCopy.nodekey = some(keyRes.get())

  debug "Retrieve dynamic bootstrap nodes"
  let dynamicBootstrapNodesRes = retrieveDynamicBootstrapNodes(
    confCopy.dnsDiscovery, confCopy.dnsDiscoveryUrl, confCopy.dnsDiscoveryNameServers
  )
  if dynamicBootstrapNodesRes.isErr():
    error "Retrieving dynamic bootstrap nodes failed",
      error = dynamicBootstrapNodesRes.error
    return err(
      "Retrieving dynamic bootstrap nodes failed: " & dynamicBootstrapNodesRes.error
    )

  let nodeRes = setupNode(confCopy, some(rng))
  if nodeRes.isErr():
    error "Failed setting up node", error = nodeRes.error
    return err("Failed setting up node: " & nodeRes.error)

  var app = App(
    version: git_version,
    conf: confCopy,
    rng: rng,
    key: confCopy.nodekey.get(),
    node: nodeRes.get(),
    dynamicBootstrapNodes: dynamicBootstrapNodesRes.get(),
  )

  ok(app)

## Setup DiscoveryV5

proc setupDiscoveryV5*(app: App): WakuDiscoveryV5 =
  let dynamicBootstrapEnrs =
    app.dynamicBootstrapNodes.filterIt(it.hasUdpPort()).mapIt(it.enr.get())

  var discv5BootstrapEnrs: seq[enr.Record]

  # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
  for enrUri in app.conf.discv5BootstrapNodes:
    addBootstrapNode(enrUri, discv5BootstrapEnrs)

  discv5BootstrapEnrs.add(dynamicBootstrapEnrs)

  let discv5Config = DiscoveryConfig.init(
    app.conf.discv5TableIpLimit, app.conf.discv5BucketIpLimit, app.conf.discv5BitsPerHop
  )

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
    some(app.node.enr),
    some(app.node.peerManager),
    app.node.topicSubscriptionQueue,
  )

proc getPorts(
    listenAddrs: seq[MultiAddress]
): AppResult[tuple[tcpPort, websocketPort: Option[Port]]] =
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

proc getRunningNetConfig(app: App): AppResult[NetConfig] =
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

  return ok(netConf)

proc updateEnr(app: var App, netConf: NetConfig): AppResult[void] =
  let record = enrConfiguration(app.conf, netConf, app.key).valueOr:
    return err("ENR setup failed: " & error)

  if isClusterMismatched(record, app.conf.clusterId):
    return err("cluster id mismatch configured shards")

  app.node.enr = record

  return ok()

proc updateApp(app: var App): AppResult[void] =
  if app.conf.tcpPort == Port(0) or app.conf.websocketPort == Port(0):
    let netConf = getRunningNetConfig(app).valueOr:
      return err("error calling updateNetConfig: " & $error)

    updateEnr(app, netConf).isOkOr:
      return err("error calling updateEnr: " & $error)

    app.node.announcedAddresses = netConf.announcedAddresses

    printNodeNetworkInfo(app.node)

  return ok()

proc startApp*(app: var App): AppResult[void] =
  let nodeRes = catch:
    (waitFor startNode(app.node, app.conf, app.dynamicBootstrapNodes))
  if nodeRes.isErr():
    return err("exception starting node: " & nodeRes.error.msg)

  nodeRes.get().isOkOr:
    return err("exception starting node: " & error)

  # Update app data that is set dynamically on node start
  app.updateApp().isOkOr:
    return err("Error in updateApp: " & $error)

  ## Discv5
  if app.conf.discv5Discovery:
    app.wakuDiscV5 = some(app.setupDiscoveryV5())

  if app.wakuDiscv5.isSome():
    let wakuDiscv5 = app.wakuDiscv5.get()
    let catchRes = catch:
      (waitFor wakuDiscv5.start())
    let startRes = catchRes.valueOr:
      return err("failed to start waku discovery v5: " & catchRes.error.msg)

    startRes.isOkOr:
      return err("failed to start waku discovery v5: " & error)

  return ok()

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): AppResult[MetricsHttpServerRef] =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort

  let metricsServerRes = MetricsHttpServerRef.new($serverIp, serverPort)
  if metricsServerRes.isErr():
    return err("metrics HTTP server start failed: " & $metricsServerRes.error)

  let server = metricsServerRes.value
  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  ok(server)

proc startMetricsLogging(): AppResult[void] =
  startMetricsLog()
  ok()

proc startMetricsServerAndLogging*(app: var App): AppResult[void] =
  if app.conf.metricsServer:
    let startMetricsServerRes = startMetricsServer(
      app.conf.metricsServerAddress,
      Port(app.conf.metricsServerPort + app.conf.portsShift),
    )
    if startMetricsServerRes.isErr():
      error "Starting metrics server failed. Continuing in current state.",
        error = startMetricsServerRes.error
    else:
      app.metricsServer = some(startMetricsServerRes.value)

  if app.conf.metricsLogging:
    let startMetricsLoggingRes = startMetricsLogging()
    if startMetricsLoggingRes.isErr():
      error "Starting metrics console logging failed. Continuing in current state.",
        error = startMetricsLoggingRes.error

  ok()

# App shutdown

proc stop*(app: App): Future[void] {.async: (raises: [Exception]).} =
  if app.conf.rest:
    await app.restServer.stop()

  if app.metricsServer.isSome():
    await app.metricsServer.get().stop()

  if app.wakuDiscv5.isSome():
    await app.wakuDiscv5.get().stop()

  if not app.node.isNil():
    await app.node.stop()
