import
  std/[json,tables,sequtils],
  chronicles,
  chronicles/topics_registry,
  chronos,
  metrics,
  metrics/chronos_httpserver,
  presto/route,
  presto/server,
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
    "Number of peers supporting each protocol, after a successful connection) ",
    labels = ["protocols"]

declarePublicGauge peer_user_agents,
    "Number of peers with each user agent",
    labels = ["user_agent"]

type
  CustomPeerInfo* = object
    # populated after discovery
    lastTimeDiscovered*: string
    peerId*: string
    enr*: string
    ip*: string
    enrCapabilities*: seq[string]
    country*: string
    city*: string

    # only after ok connection
    lastTimeConnected*: string
    supportedProtocols*: seq[string]
    userAgent*: string

  CustomPeersTable* = Table[string, CustomPeerInfo]
  CustomPeersTableRef* = ref CustomPeersTable

# GET /allpeersinfo
proc installHandler*(router: var RestRouter, allPeers: CustomPeersTableRef) =
  router.api(MethodGet, "/allpeersinfo") do () -> RestApiResponse:
    let values = toSeq(allPeers.keys()).mapIt(allPeers[it])
    return RestApiResponse.response($(%values), contentType="application/json")

proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      raiseAssert("Exception while starting metrics HTTP server: " & e.msg)

    info "Metrics HTTP server started", serverIp, serverPort