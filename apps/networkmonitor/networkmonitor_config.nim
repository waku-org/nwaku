import
  std/strutils,
  chronicles,
  chronicles/topics_registry,
  chronos,
  confutils,
  stew/results,
  stew/shims/net

type
  NetworkMonitorConf* = object
    logLevel* {.
      desc: "Sets the log level",
      defaultValue: LogLevel.INFO,
      name: "log-level",
      abbr: "l" .}: LogLevel

    timeout* {.
      desc: "Timeout to consider that the connection failed",
      defaultValue: chronos.seconds(10),
      name: "timeout",
      abbr: "t" }: chronos.Duration

    bootstrapNodes* {.
      desc: "Bootstrap ENR node. Argument may be repeated.",
      defaultValue: @[""],
      name: "bootstrap-node",
      abbr: "b" }: seq[string]

    dnsDiscoveryUrl* {.
      desc: "URL for DNS node list in format 'enrtree://<key>@<fqdn>'",
      defaultValue: ""
      name: "dns-discovery-url" }: string

    pubsubTopics* {.
      desc: "Default pubsub topic to subscribe to. Argument may be repeated."
      name: "pubsub-topic" .}: seq[string]

    refreshInterval* {.
      desc: "How often new peers are discovered and connected to (in seconds)",
      defaultValue: 5,
      name: "refresh-interval",
      abbr: "r" }: int

    clusterId* {.
      desc: "Cluster id that the node is running in. Node in a different cluster id is disconnected."
      defaultValue: 1
      name: "cluster-id" }: uint32

    rlnRelay* {.
        desc: "Enable spam protection through rln-relay: true|false",
        defaultValue: true
        name: "rln-relay" }: bool

    rlnRelayDynamic* {.
      desc: "Enable  waku-rln-relay with on-chain dynamic group management: true|false",
      defaultValue: true
      name: "rln-relay-dynamic" }: bool

    rlnRelayTreePath* {.
      desc: "Path to the RLN merkle tree sled db (https://github.com/spacejam/sled)",
      defaultValue: ""
      name: "rln-relay-tree-path" }: string

    rlnRelayEthClientAddress* {.
      desc: "WebSocket address of an Ethereum testnet client e.g., http://localhost:8540/",
      defaultValue: "http://localhost:8540/",
      name: "rln-relay-eth-client-address" }: string

    rlnRelayEthContractAddress* {.
      desc: "Address of membership contract on an Ethereum testnet",
      defaultValue: "",
      name: "rln-relay-eth-contract-address" }: string

    ## Prometheus metrics config
    metricsServer* {.
      desc: "Enable the metrics server: true|false"
      defaultValue: true
      name: "metrics-server" }: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server."
      defaultValue: parseIpAddress("127.0.0.1")
      name: "metrics-server-address" }: IpAddress

    metricsServerPort* {.
      desc: "Listening HTTP port of the metrics server."
      defaultValue: 8008
      name: "metrics-server-port" }: uint16

    ## Custom metrics rest server
    metricsRestAddress* {.
      desc: "Listening address of the metrics rest server.",
      defaultValue: "127.0.0.1",
      name: "metrics-rest-address" }: string
    metricsRestPort* {.
      desc: "Listening HTTP port of the metrics rest server.",
      defaultValue: 8009,
      name: "metrics-rest-port" }: uint16

proc parseCmdArg*(T: type IpAddress, p: string): T =
  try:
    result = parseIpAddress(p)
  except CatchableError as e:
    raise newException(ValueError, "Invalid IP address")

proc completeCmdArg*(T: type IpAddress, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type chronos.Duration, p: string): T =
  try:
    result = chronos.seconds(parseInt(p))
  except CatchableError as e:
    raise newException(ValueError, "Invalid duration value")

proc completeCmdArg*(T: type chronos.Duration, val: string): seq[string] =
  return @[]

proc loadConfig*(T: type NetworkMonitorConf): Result[T, string] =
  try:
    let conf = NetworkMonitorConf.load(version=git_version)
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())
