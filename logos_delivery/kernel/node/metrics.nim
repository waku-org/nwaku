{.push raises: [].}

import chronicles, chronos, pkg/metrics, metrics/chronos_httpserver
import
  logos_delivery/kernel/[net/auto_port, rln/protocol_metrics as rln_metrics, common/utils/collector],
  logos_delivery/kernel/node/peer_manager/peer_manager

declarePublicGauge logos_delivery_version,
  "Waku version info (in git describe format)", ["version"]

declarePublicCounter logos_delivery_node_errors, "number of wakunode errors", ["type"]

declarePublicGauge logos_delivery_lightpush_peers, "number of lightpush peers"

declarePublicGauge logos_delivery_filter_peers, "number of filter peers"

declarePublicGauge logos_delivery_store_peers, "number of store peers"

declarePublicGauge logos_delivery_px_peers,
  "number of peers (in the node's peerManager) supporting the peer exchange protocol"

declarePublicCounter logos_delivery_node_messages,
  "number of messages received", ["type"]

declarePublicHistogram logos_delivery_histogram_message_size,
  "message size histogram in kB",
  buckets = [
    0.0, 1.0, 3.0, 5.0, 15.0, 50.0, 75.0, 100.0, 125.0, 150.0, 500.0, 700.0, 1000.0, Inf
  ]

const LogInterval = 10.minutes

logScope:
  topics = "waku node metrics"

type MetricsServerConf* = object
  httpAddress*: IpAddress
  httpPort*: Port
  logging*: bool

proc startMetricsLog*() =
  var logMetrics: CallbackFunc

  var cumulativeErrors = 0.float64
  var cumulativeConns = 0.float64

  let logRlnMetrics = getRlnMetricsLogger()

  logMetrics = CallbackFunc(
    proc(udata: pointer) {.gcsafe.} =
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.

      # track cumulative values
      let freshErrorCount =
        parseAndAccumulate(logos_delivery_node_errors, cumulativeErrors)
      let freshConnCount =
        parseAndAccumulate(logos_delivery_node_conns_initiated, cumulativeConns)

      let totalMessages = collectorAsF64(logos_delivery_node_messages)
      let storePeers = collectorAsF64(logos_delivery_store_peers)
      let pxPeers = collectorAsF64(logos_delivery_px_peers)
      let lightpushPeers = collectorAsF64(logos_delivery_lightpush_peers)
      let filterPeers = collectorAsF64(logos_delivery_filter_peers)

      info "Node metrics",
        connectionsInitiated = $freshConnCount,
        messages = totalMessages,
        storePeers = storePeers,
        peerExchangePeers = pxPeers,
        lightpushPeers = lightpushPeers,
        filterPeers = filterPeers,
        errors = $freshErrorCount

      # Start protocol specific metrics logging
      logRlnMetrics()

      discard setTimer(Moment.fromNow(LogInterval), logMetrics)
  )

  discard setTimer(Moment.fromNow(LogInterval), logMetrics)

type StartedMetricsServer* = tuple[server: MetricsHttpServerRef, port: Port]

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Future[Result[StartedMetricsServer, string]] {.async.} =
  proc attempt(
      port: Port
  ): Future[Result[StartedMetricsServer, string]] {.async: (raises: []).} =
    info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $port

    let server = MetricsHttpServerRef.new($serverIp, port).valueOr:
      return err("fail to start service metrics server, attempt:" & $error)

    try:
      await server.start()
    except CatchableError:
      return
        err("exception while startMetricsServer, attempt: " & getCurrentExceptionMsg())

    debug "Metrics HTTP server started", serverIp = $serverIp, serverPort = $port
    return ok((server: server, port: port))

  let started = (await tryWithAutoPort[StartedMetricsServer](serverPort, attempt)).valueOr:
    return err("metrics HTTP server start failed: " & error)
  return ok(started)

proc startMetricsServerAndLogging*(
    conf: MetricsServerConf
): Future[Result[StartedMetricsServer, string]] {.async.} =
  let started = (await (startMetricsServer(conf.httpAddress, conf.httpPort))).valueOr:
    return err("Starting metrics server failed. Continuing in current state:" & $error)

  if conf.logging:
    startMetricsLog()

  return ok(started)
