import
  chronicles,
  confutils,
  confutils/std/net,
  std/net,
  stew/results,
  regex


type EthRpcUrl = distinct string

type NetworkSpammerConfig* = object
  clusterId* {.
    desc:
      "Cluster id that the node is running in. Node in a different cluster id is disconnected.",
    defaultValue: 1,
    name: "cluster-id"
  .}: uint32

  pubsubTopics* {.
    desc: "Default pubsub topic to subscribe to. Argument may be repeated.",
    name: "pubsub-topic"
  .}: seq[string]

  rlnRelayDynamic* {.
    desc: "Enable  waku-rln-relay with on-chain dynamic group management: true|false",
    defaultValue: true,
    name: "rln-relay-dynamic"
  .}: bool

  rlnRelayTreePath* {.
    desc: "Path to the RLN merkle tree sled db (https://github.com/spacejam/sled)",
    defaultValue: "",
    name: "rln-relay-tree-path"
  .}: string

  rlnRelayEthClientAddress* {.
    desc: "HTTP address of an Ethereum testnet client e.g., http://localhost:8540/",
    defaultValue: "http://localhost:8540/",
    name: "rln-relay-eth-client-address"
  .}: EthRpcUrl

  rlnRelayEthContractAddress* {.
    desc: "Address of membership contract on an Ethereum testnet",
    defaultValue: "",
    name: "rln-relay-eth-contract-address"
  .}: string

  rlnEpochSizeSec* {.
    desc:
      "Epoch size in seconds used to rate limit RLN memberships. Default is 1 second.",
    defaultValue: 1,
    name: "rln-relay-epoch-sec"
  .}: uint64

  rlnRelayUserMessageLimit* {.
    desc:
      "Set a user message limit for the rln membership registration. Must be a positive integer. Default is 1.",
    defaultValue: 1,
    name: "rln-relay-user-message-limit"
  .}: uint64

  msgRate* {.
    desc: "Rate of messages being published - msg per sec",
    defaultValue: 1,
    name: "msg-rate"
  .}: uint64

  logLevel* {.
    desc: "Sets the log level",
    defaultValue: LogLevel.INFO,
    name: "log-level",
    abbr: "l"
  .}: LogLevel

  bootstrapNodes* {.
    desc: "Bootstrap ENR node. Argument may be repeated.",
    defaultValue: @[""],
    name: "bootstrap-node",
    abbr: "b"
  .}: seq[string]

    ## Prometheus metrics config
  metricsServer* {.
    desc: "Enable the metrics server: true|false",
    defaultValue: true,
    name: "metrics-server"
  .}: bool

  metricsServerAddress* {.
    desc: "Listening address of the metrics server.",
    defaultValue: parseIpAddress("127.0.0.1"),
    name: "metrics-server-address"
  .}: IpAddress

  metricsServerPort* {.
    desc: "Listening HTTP port of the metrics server.",
    defaultValue: 8008,
    name: "metrics-server-port"
  .}: uint16

  ## Custom metrics rest server
  metricsRestAddress* {.
    desc: "Listening address of the metrics rest server.",
    defaultValue: "127.0.0.1",
    name: "metrics-rest-address"
  .}: string
  metricsRestPort* {.
    desc: "Listening HTTP port of the metrics rest server.",
    defaultValue: 8009,
    name: "metrics-rest-port"
  .}: uint16


proc parseCmdArg*(T: type IpAddress, p: string): T =
  try:
    result = parseIpAddress(p)
  except CatchableError as e:
    raise newException(ValueError, "Invalid IP address")

proc completeCmdArg*(T: type IpAddress, val: string): seq[string] =
  return @[]

proc completeCmdArg*(T: type EthRpcUrl, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type EthRpcUrl, s: string): T =
  ## allowed patterns:
  ## http://url:port
  ## https://url:port
  ## http://url:port/path
  ## https://url:port/path
  ## http://url/with/path
  ## http://url:port/path?query
  ## https://url:port/path?query
  ## disallowed patterns:
  ## any valid/invalid ws or wss url
  var httpPattern =
    re2"^(https?):\/\/((localhost)|([\w_-]+(?:(?:\.[\w_-]+)+)))(:[0-9]{1,5})?([\w.,@?^=%&:\/~+#-]*[\w@?^=%&\/~+#-])*"
  var wsPattern =
    re2"^(wss?):\/\/((localhost)|([\w_-]+(?:(?:\.[\w_-]+)+)))(:[0-9]{1,5})?([\w.,@?^=%&:\/~+#-]*[\w@?^=%&\/~+#-])*"
  if regex.match(s, wsPattern):
    raise newException(
      ValueError, "Websocket RPC URL is not supported, Please use an HTTP URL"
    )
  if not regex.match(s, httpPattern):
    raise newException(ValueError, "Invalid HTTP RPC URL")
  return EthRpcUrl(s)

proc loadConfig*(T: type NetworkSpammerConfig): Result[T, string] =
  try:
    let conf = NetworkSpammerConfig.load(version = git_version)
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())