import
  confutils,
  std/tables,
  chronicles,
  chronicles/topics_registry,
  metrics,
  metrics/chronos_httpserver,
  stew/shims/net

logScope:
  topics = "networkmonitor_metrics"

# TODO: remove dummy test
declarePublicHistogram networkmonitor_example, "my test"

# TODO: add metrics
# discovered nodes with Relay, Store, Filter, Lightpush capabilities
# full enrs
# ips (useful for location)

proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      raiseAssert("Exception while starting metrics HTTP server: " & e.msg)

    info "Metrics HTTP server started", serverIp, serverPort