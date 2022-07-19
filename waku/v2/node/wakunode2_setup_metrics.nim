{.push raises: [Defect].}

import
  stew/results,
  stew/shims/net,
  chronicles,
  chronos,
  metrics,
  metrics/chronos_httpserver,
  ./config,
  ./wakunode2

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

  logMetrics = proc(udata: pointer) =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.
      var totalMessages = 0.float64
      for key in waku_node_messages.metrics.keys():
        try:
          totalMessages = totalMessages + waku_node_messages.value(key)
        except KeyError:
          discard

    info "Node metrics", totalMessages
    discard setTimer(Moment.fromNow(2.seconds), logMetrics)
  
  discard setTimer(Moment.fromNow(2.seconds), logMetrics)
  