when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  chronos,
  metrics,
  metrics/chronos_httpserver
import
  ../waku_filter/protocol_metrics as filter_metrics,
  ../waku_rln_relay/protocol_metrics as rln_metrics,

  ../utils/collector,
  ./peer_manager,
  ./waku_node

const LogInterval = 30.seconds

logScope:
  topics = "waku node metrics"


type
  # https://github.com/nim-lang/Nim/issues/17369
  MetricsLogger = proc(udata: pointer) {.gcsafe, raises: [Defect].}

proc startMetricsLog*() =
  var logMetrics: MetricsLogger

  var cumulativeErrors = 0.float64
  var cumulativeConns = 0.float64

  let logRlnMetrics = getRlnMetricsLogger()

  logMetrics = proc(udata: pointer) =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.

      # track cumulative values
      let freshErrorCount = parseAndAccumulate(waku_node_errors, cumulativeErrors)
      let freshConnCount = parseAndAccumulate(waku_node_conns_initiated, cumulativeConns)

      let totalMessages = collectorAsF64(waku_node_messages)
      let storePeers = collectorAsF64(waku_store_peers)
      let pxPeers = collectorAsF64(waku_px_peers)
      let lightpushPeers = collectorAsF64(waku_lightpush_peers)
      let filterPeers = collectorAsF64(waku_filter_peers)
      let filterSubscribers = collectorAsF64(waku_legacy_filter_subscribers)

      info "Total connections initiated", count = $freshConnCount
      info "Total messages", count = totalMessages
      info "Total store peers", count = storePeers
      info "Total peer exchange peers", count = pxPeers
      info "Total lightpush peers", count = lightpushPeers
      info "Total filter peers", count = filterPeers
      info "Total active filter subscriptions", count = filterSubscribers
      info "Total errors", count = $freshErrorCount

      # Start protocol specific metrics logging
      logRlnMetrics()

    discard setTimer(Moment.fromNow(LogInterval), logMetrics)

  discard setTimer(Moment.fromNow(LogInterval), logMetrics)
