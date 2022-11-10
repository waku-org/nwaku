when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/shims/net,
  chronicles,
  chronos,
  metrics,
  metrics/chronos_httpserver
import
  ../protocol/waku_filter/protocol_metrics as filter_metrics,
  ../protocol/waku_swap/waku_swap,
  ../utils/collector,
  ./peer_manager/peer_manager,
  ./waku_node

when defined(rln):
  import ../protocol/waku_rln_relay/waku_rln_relay_metrics


const LogInterval = 30.seconds

logScope:
  topics = "waku node metrics"


proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      raiseAssert("Exception while starting metrics HTTP server: " & e.msg)

    info "Metrics HTTP server started", serverIp, serverPort

type
  # https://github.com/nim-lang/Nim/issues/17369
  MetricsLogger = proc(udata: pointer) {.gcsafe, raises: [Defect].}

proc startMetricsLog*() =
  var logMetrics: MetricsLogger

  var cumulativeErrors = 0.float64
  var cumulativeConns = 0.float64

  when defined(rln):
    let logRlnMetrics = getRlnMetricsLogger()

  logMetrics = proc(udata: pointer) =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.

      # track cumulative values
      let freshErrorCount = parseAndAccumulate(waku_node_errors, cumulativeErrors)
      let freshConnCount = parseAndAccumulate(waku_node_conns_initiated, cumulativeConns)

      info "Total connections initiated", count = freshConnCount
      info "Total messages", count = collectorAsF64(waku_node_messages)
      info "Total swap peers", count = collectorAsF64(waku_swap_peers_count)
      info "Total filter peers", count = collectorAsF64(waku_filter_peers)
      info "Total store peers", count = collectorAsF64(waku_store_peers)
      info "Total lightpush peers", count = collectorAsF64(waku_lightpush_peers)
      info "Total peer exchange peers", count = collectorAsF64(waku_px_peers)
      info "Total errors", count = freshErrorCount
      info "Total active filter subscriptions", count = collectorAsF64(waku_filter_subscribers)

      # Start protocol specific metrics logging
      when defined(rln):
        logRlnMetrics()

    discard setTimer(Moment.fromNow(LogInterval), logMetrics)
  
  discard setTimer(Moment.fromNow(LogInterval), logMetrics)
