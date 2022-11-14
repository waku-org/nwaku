when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}
  
import
  std/[json,tables,sequtils],
  chronicles,
  chronicles/topics_registry,
  chronos,
  json_serialization,
  metrics,
  metrics/chronos_httpserver,
  presto/route,
  presto/server,
  stew/results,
  stew/shims/net

logScope:
  topics = "networkmonitor_metrics"

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

  # Stores information about all discovered/connected peers
  CustomPeersTableRef* = TableRef[string, CustomPeerInfo]

  # stores the content topic and the count of rx messages
  ContentTopicMessageTableRef* = TableRef[string, int]

proc installHandler*(router: var RestRouter,
                     allPeers: CustomPeersTableRef,
                     numMessagesPerContentTopic: ContentTopicMessageTableRef) =
  router.api(MethodGet, "/allpeersinfo") do () -> RestApiResponse:
    let values = toSeq(allPeers.values())
    return RestApiResponse.response(values.toJson(), contentType="application/json")
  router.api(MethodGet, "/contenttopics") do () -> RestApiResponse:
    # TODO: toJson() includes the hash
    return RestApiResponse.response($(%numMessagesPerContentTopic), contentType="application/json")

proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port): Result[void, string] =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      error("Failed to start metrics HTTP server", serverIp=serverIp, serverPort=serverPort, msg=e.msg)

    info "Metrics HTTP server started", serverIp, serverPort
    ok()