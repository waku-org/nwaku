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
      defaultValue: LogLevel.DEBUG,
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

    refreshInterval* {.
      desc: "How often new peers are discovered and connected to (in minutes)",
      defaultValue: 10,
      name: "refresh-interval",
      abbr: "r" }: int

    ## Prometheus metrics config
    metricsServer* {.
      desc: "Enable the metrics server: true|false"
      defaultValue: true
      name: "metrics-server" }: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server."
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "metrics-server-address" }: ValidIpAddress

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
    

proc parseCmdArg*(T: type ValidIpAddress, p: string): T =
  try:
    result = ValidIpAddress.init(p)
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid IP address")

proc completeCmdArg*(T: type ValidIpAddress, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type chronos.Duration, p: string): T =
  try:
    result = chronos.seconds(parseInt(p))
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid duration value")

proc completeCmdArg*(T: type chronos.Duration, val: string): seq[string] =
  return @[]

proc loadConfig*(T: type NetworkMonitorConf): Result[T, string] =
  try:
    let conf = NetworkMonitorConf.load()
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())