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

# Metric ideas:
# histogram with latency
# number of peers hosted behind each ip

# On top of our custom metrics, the following are reused from nim-eth
#routing_table_nodes{state=""}
#routing_table_nodes{state="seen"}
#discovery_message_requests_outgoing_total{response=""}
#discovery_message_requests_outgoing_total{response="no_response"}

declarePublicGauge peer_type_as_per_enr,
    "Number of peers supporting each capability according the the ENR",
    labels = ["capability"]

declarePublicGauge peer_type_as_per_protocol,
    "Number of peers supporting each capability according to the protocol (requiere successful connection) ",
    labels = ["capability"]

# hackish way for exponse strings, not performant at all
declarePublicGauge discovered_peers_list,
    "Discovered peers in the waku network and its information",
    labels = ["enr",
              "ip",
              "capabilities",
              "discovered_timestamp",
              #"citiy",
              #"country",
              ]

proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      raiseAssert("Exception while starting metrics HTTP server: " & e.msg)

    info "Metrics HTTP server started", serverIp, serverPort