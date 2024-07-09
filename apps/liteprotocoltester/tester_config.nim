import
  std/[strutils, strformat],
  results,
  chronos,
  regex,
  confutils,
  confutils/defs,
  confutils/std/net,
  confutils/toml/defs as confTomlDefs,
  confutils/toml/std/net as confTomlNet,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  nimcrypto/utils,
  secp256k1,
  json
import
  waku/[
    common/confutils/envvar/defs as confEnvvarDefs,
    common/confutils/envvar/std/net as confEnvvarNet,
    common/logging,
    factory/external_config,
    waku/waku_core,
  ]

export confTomlDefs, confTomlNet, confEnvvarDefs, confEnvvarNet

const
  LitePubsubTopic* = PubsubTopic("/waku/2/default-waku/proto")
  LiteContentTopic* = ContentTopic("/tester/1/light-pubsub-example/proto")

type TesterFunctionality* = enum
  SENDER # pumps messages to the network
  RECEIVER # gather and analyze messages from the network

type LiteProtocolTesterConf* = object
  configFile* {.
    desc:
      "Loads configuration from a TOML file (cmd-line parameters take precedence) for the light waku node",
    name: "config-file"
  .}: Option[InputFile]

  ## Log configuration
  logLevel* {.
    desc:
      "Sets the log level for process. Supported levels: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL",
    defaultValue: logging.LogLevel.DEBUG,
    name: "log-level"
  .}: logging.LogLevel

  logFormat* {.
    desc:
      "Specifies what kind of logs should be written to stdout. Suported formats: TEXT, JSON",
    defaultValue: logging.LogFormat.TEXT,
    name: "log-format"
  .}: logging.LogFormat

  ## Test configuration
  servicenode* {.desc: "Peer multiaddr of the service node.", name: "service-node".}:
    string

  nat* {.
    desc:
      "Specify method to use for determining public address. " &
      "Must be one of: any, none, upnp, pmp, extip:<IP>.",
    defaultValue: "any"
  .}: string

  testFunc* {.
    desc: "Specifies the lite protocol tester side. Supported values: sender, receiver.",
    defaultValue: TesterFunctionality.RECEIVER,
    name: "test-func"
  .}: TesterFunctionality

  numMessages* {.
    desc: "Number of messages to send.", defaultValue: 120, name: "num-messages"
  .}: uint32

  delayMessages* {.
    desc: "Delay between messages in milliseconds.",
    defaultValue: 1000,
    name: "delay-messages"
  .}: uint32

  pubsubTopics* {.
    desc: "Default pubsub topic to subscribe to. Argument may be repeated.",
    defaultValue: @[LitePubsubTopic],
    name: "pubsub-topic"
  .}: seq[PubsubTopic]

  ## TODO: extend lite protocol tester configuration based on testing needs
  # shards* {.
  #   desc: "Shards index to subscribe to [0..MAX_SHARDS-1]. Argument may be repeated.",
  #   defaultValue: @[],
  #   name: "shard"
  # .}: seq[uint16]
  contentTopics* {.
    desc: "Default content topic to subscribe to. Argument may be repeated.",
    defaultValue: @[LiteContentTopic],
    name: "content-topic"
  .}: seq[ContentTopic]

  clusterId* {.
    desc:
      "Cluster id that the node is running in. Node in a different cluster id is disconnected.",
    defaultValue: 0,
    name: "cluster-id"
  .}: uint32

  ## Tester REST service configuration
  restAddress* {.
    desc: "Listening address of the REST HTTP server.",
    defaultValue: parseIpAddress("127.0.0.1"),
    name: "rest-address"
  .}: IpAddress

  restPort* {.
    desc: "Listening port of the REST HTTP server.",
    defaultValue: 8654,
    name: "rest-port"
  .}: uint16

  restAllowOrigin* {.
    desc:
      "Allow cross-origin requests from the specified origin." &
      "Argument may be repeated." & "Wildcards: * or ? allowed." &
      "Ex.: \"localhost:*\" or \"127.0.0.1:8080\"",
    defaultValue: @["*"],
    name: "rest-allow-origin"
  .}: seq[string]

{.push warning[ProveInit]: off.}

proc load*(T: type LiteProtocolTesterConf, version = ""): ConfResult[T] =
  try:
    let conf = LiteProtocolTesterConf.load(
      version = version,
      secondarySources = proc(
          conf: LiteProtocolTesterConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile("liteprotocoltester"))
      ,
    )
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

{.pop.}
