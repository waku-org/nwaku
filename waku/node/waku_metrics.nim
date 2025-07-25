{.push raises: [].}

import chronicles, chronos, metrics, metrics/chronos_httpserver
import
  ../waku_rln_relay/protocol_metrics as rln_metrics,
  ../utils/collector,
  ./peer_manager,
  ./waku_node

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
      let freshErrorCount = parseAndAccumulate(waku_node_errors, cumulativeErrors)
      let freshConnCount =
        parseAndAccumulate(waku_node_conns_initiated, cumulativeConns)

      let totalMessages = collectorAsF64(waku_node_messages)
      let storePeers = collectorAsF64(waku_store_peers)
      let pxPeers = collectorAsF64(waku_px_peers)
      let lightpushPeers = collectorAsF64(waku_lightpush_peers)
      let filterPeers = collectorAsF64(waku_filter_peers)

      info "Total connections initiated", count = $freshConnCount
      info "Total messages", count = totalMessages
      info "Total store peers", count = storePeers
      info "Total peer exchange peers", count = pxPeers
      info "Total lightpush peers", count = lightpushPeers
      info "Total filter peers", count = filterPeers
      info "Total errors", count = $freshErrorCount

      # Start protocol specific metrics logging
      logRlnMetrics()

      discard setTimer(Moment.fromNow(LogInterval), logMetrics)
  )

  discard setTimer(Moment.fromNow(LogInterval), logMetrics)

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Future[Result[MetricsHttpServerRef, string]] {.async.} =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort

  let server = MetricsHttpServerRef.new($serverIp, serverPort).valueOr:
    return err("metrics HTTP server start failed: " & $error)

  try:
    await server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  return ok(server)

proc startMetricsServerAndLogging*(
    conf: MetricsServerConf, portsShift: uint16
): Future[Result[MetricsHttpServerRef, string]] {.async.} =
  var metricsServer: MetricsHttpServerRef
  metricsServer = (
    await (
      startMetricsServer(conf.httpAddress, Port(conf.httpPort.uint16 + portsShift))
    )
  ).valueOr:
    return err("Starting metrics server failed. Continuing in current state:" & $error)

  if conf.logging:
    startMetricsLog()

  return ok(metricsServer)
