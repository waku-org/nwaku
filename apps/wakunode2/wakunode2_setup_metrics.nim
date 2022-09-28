{.push raises: [Defect].}

import
  stew/results,
  stew/shims/net,
  chronicles,
  chronos,
  metrics,
  metrics/chronos_httpserver
import
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_store/protocol_metrics,
  ../../waku/v2/protocol/waku_lightpush,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/protocol/waku_peer_exchange,
  ../../waku/v2/utils/collector,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/waku_node,
  ./config

when defined(rln) or defined(rlnzerokit):
  import ../../waku/v2/protocol/waku_rln_relay/waku_rln_relay_metrics


logScope:
  topics = "wakunode.setup.metrics"


proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      raiseAssert("Exception while starting metrics HTTP server: " & e.msg)

    info "Metrics HTTP server started", serverIp, serverPort



proc startMetricsLog*() =
  # https://github.com/nim-lang/Nim/issues/17369
  var logMetrics: proc(udata: pointer) {.gcsafe, raises: [Defect].}

  var cumulativeErrors = 0.float64
  var cumulativeConns = 0.float64

  when defined(rln) or defined(rlnzerokit):
    let logRlnMetrics = getRlnMetricsLogger()

  logMetrics = proc(udata: pointer) =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.

      # track cumulative values
      let freshErrorCount = parseAndAccumulate(waku_node_errors, cumulativeErrors)
      let freshConnCount = parseAndAccumulate(waku_node_conns_initiated, cumulativeConns)
      
      info "Total connections initiated", count = freshConnCount
      info "Total messages", count = parseCollectorIntoF64(waku_node_messages)
      info "Total swap peers", count = parseCollectorIntoF64(waku_swap_peers_count)
      info "Total filter peers", count = parseCollectorIntoF64(waku_filter_peers)
      info "Total store peers", count = parseCollectorIntoF64(waku_store_peers)
      info "Total lightpush peers", count = parseCollectorIntoF64(waku_lightpush_peers)
      info "Total peer exchange peers", count = parseCollectorIntoF64(waku_px_peers)
      info "Total errors", count = freshErrorCount
      info "Total active filter subscriptions", count = parseCollectorIntoF64(waku_filter_subscribers)

      # Start protocol specific metrics logging
      when defined(rln) or defined(rlnzerokit):
        logRlnMetrics()

    discard setTimer(Moment.fromNow(30.seconds), logMetrics)
  
  discard setTimer(Moment.fromNow(30.seconds), logMetrics)

  
