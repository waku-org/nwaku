{.push raises: [Defect].}

import
  stew/results,
  stew/shims/net,
  chronicles,
  chronos,
  metrics,
  metrics/chronos_httpserver,
  ./config,
  ./wakunode2,
  ../protocol/waku_filter,
  ../protocol/waku_store,
  ../protocol/waku_lightpush,
  ../protocol/waku_swap/waku_swap

logScope:
  topics = "wakunode.setup.metrics"


proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      raiseAssert("Exception while starting metrics HTTP server: " & e.msg)

    info "Metrics HTTP server started", serverIp, serverPort

proc parseCollectorIntoF64(collector: Collector): float64 = 
  var total = 0.float64
  for key in collector.metrics.keys():
    try:
      total = total + collector.value(key)
    except KeyError:
      discard
  return total

proc startMetricsLog*() =
  # https://github.com/nim-lang/Nim/issues/17369
  var logMetrics: proc(udata: pointer) {.gcsafe, raises: [Defect].}

  var cumulativeErrors = 0.float64
  var cumulativeConns = 0.float64

  logMetrics = proc(udata: pointer) =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.

      let totalErrors = parseCollectorIntoF64(waku_node_errors)
      let totalConnections = parseCollectorIntoF64(waku_node_conns_initiated)

      # track cumulative, and then max.
      let freshErrorCount = max(totalErrors - cumulativeErrors, 0)
      let freshConnCount = max(totalConnections - cumulativeConns, 0)
      
      cumulativeErrors = totalErrors
      cumulativeConns = totalConnections
      info "Total connections initiated", count = freshConnCount
      info "Total messages", count = parseCollectorIntoF64(waku_node_messages)
      info "Total swap peers", count = parseCollectorIntoF64(waku_swap_peers_count)
      info "Total filter peers", count = parseCollectorIntoF64(waku_filter_peers)
      info "Total store peers", count = parseCollectorIntoF64(waku_store_peers)
      info "Total lightpush peers", count = parseCollectorIntoF64(waku_lightpush_peers)
      info "Total errors", count = freshErrorCount
      info "Total active filter subscriptions", count = parseCollectorIntoF64(waku_filter_subscribers)

    discard setTimer(Moment.fromNow(30.seconds), logMetrics)
  
  discard setTimer(Moment.fromNow(30.seconds), logMetrics)
  