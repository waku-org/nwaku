{.push raises: [].}

import chronicles, chronos, metrics, metrics/chronos_httpserver
import
  ../waku_rln_relay/protocol_metrics as rln_metrics,
  ../utils/collector,
  ./peer_manager,
  ./waku_node,
  ../factory/external_config

const LogInterval = 10.minutes

logScope:
  topics = "waku node metrics"

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
): Result[MetricsHttpServerRef, string] =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort

  let server = MetricsHttpServerRef.new($serverIp, serverPort).valueOr:
    return err("metrics HTTP server start failed: " & $error)

  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  return ok(server)

proc startMetricsServerAndLogging*(
    conf: WakuNodeConf
): Result[MetricsHttpServerRef, string] =
  var metricsServer: MetricsHttpServerRef
  if conf.metricsServer:
    metricsServer = startMetricsServer(
      conf.metricsServerAddress, Port(conf.metricsServerPort + conf.portsShift)
    ).valueOr:
      return
        err("Starting metrics server failed. Continuing in current state:" & $error)

  if conf.metricsLogging:
    startMetricsLog()

  return ok(metricsServer)
