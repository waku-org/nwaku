import
  std/strutils,
  confutils, confutils/defs, confutils/std/net,
  chronicles, chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  nimcrypto/utils,
  eth/keys

type
  Fleet* =  enum
    none
    prod
    staging
    test

  WakuNodeConf* = object
    logLevel* {.
      desc: "Sets the log level."
      defaultValue: LogLevel.INFO
      name: "log-level" }: LogLevel

    libp2pAddress* {.
      defaultValue: defaultListenAddress(config)
      desc: "Listening address for the LibP2P traffic."
      name: "listen-address"}: ValidIpAddress

    tcpPort* {.
      desc: "TCP listening port."
      defaultValue: 60000
      name: "tcp-port" }: Port

    udpPort* {.
      desc: "UDP listening port."
      defaultValue: 60000
      name: "udp-port" }: Port

    portsShift* {.
      desc: "Add a shift to all port numbers."
      defaultValue: 0
      name: "ports-shift" }: uint16

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>."
      defaultValue: "any" }: string

    discovery* {.
      desc: "Enable/disable discovery v4."
      defaultValue: true
      name: "discovery" }: bool

    noListen* {.
      desc: "Disable listening for incoming peers."
      defaultValue: false
      name: "no-listen" }: bool

    fleet* {.
      desc: "Select the fleet to connect to."
      defaultValue: Fleet.none
      name: "fleet" }: Fleet

    bootnodes* {.
      desc: "Enode URL to bootstrap P2P discovery with. Argument may be repeated."
      name: "bootnode" }: seq[string]

    staticnodes* {.
      desc: "Enode URL to directly connect with. Argument may be repeated."
      name: "staticnode" }: seq[string]

    storenode* {.
      desc: "Enode URL to query for storage.",
      defaultValue: ""
      name: "storenode" }: string

    store* {.
      desc: "Flag whether to start store protocol",
      defaultValue: false
      name: "store" }: bool

    filter* {.
      desc: "Flag whether to start filter protocol",
      defaultValue: false
      name: "filter" }: bool
    
    relay* {.
      desc: "Flag whether to start relay protocol",
      defaultValue: false
      name: "relay" }: bool

    filternode* {.
      desc: "Enode URL to filter.",
      defaultValue: ""
      name: "filternode" }: string

    whisper* {.
      desc: "Enable the Whisper protocol."
      defaultValue: false
      name: "whisper" }: bool

    whisperBridge* {.
      desc: "Enable the Whisper protocol and bridge with Waku protocol."
      defaultValue: false
      name: "whisper-bridge" }: bool

    lightNode* {.
      desc: "Run as light node (no message relay).",
      defaultValue: false
      name: "light-node" }: bool

    wakuTopicInterest* {.
      desc: "Run as node with a topic-interest",
      defaultValue: false
      name: "waku-topic-interest" }: bool

    wakuPow* {.
      desc: "PoW requirement of Waku node.",
      defaultValue: 0.002
      name: "waku-pow" }: float64

    # NOTE: Signature is different here, we return PrivateKey and not KeyPair
    nodekey* {.
      desc: "P2P node private key as hex.",
      defaultValue: crypto.PrivateKey.random(Secp256k1, keys.newRng()[]).tryGet()
      name: "nodekey" }: crypto.PrivateKey
    # TODO: Add nodekey file option

    bootnodeOnly* {.
      desc: "Run only as discovery bootnode."
      defaultValue: false
      name: "bootnode-only" }: bool

    rpc* {.
      desc: "Enable Waku RPC server.",
      defaultValue: true
      name: "rpc" }: bool

    rpcAddress* {.
      desc: "Listening address of the RPC server.",
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "rpc-address" }: ValidIpAddress

    rpcPort* {.
      desc: "Listening port of the RPC server.",
      defaultValue: 8545
      name: "rpc-port" }: uint16

    metricsServer* {.
      desc: "Enable the metrics server."
      defaultValue: false
      name: "metrics-server" }: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server."
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "metrics-server-address" }: ValidIpAddress

    metricsServerPort* {.
      desc: "Listening HTTP port of the metrics server."
      defaultValue: 8008
      name: "metrics-server-port" }: uint16

    logMetrics* {.
      desc: "Enable metrics logging."
      defaultValue: false
      name: "log-metrics" }: bool
      
    topics* {.
      desc: "Default topics to subscribe to (space seperated list)."
      defaultValue: "waku"
      name: "topics" .}: string

    # TODO:
    # - discv5 + topic register
    # - mailserver functionality

# NOTE: Keys are different in nim-libp2p
proc parseCmdArg*(T: type crypto.PrivateKey, p: TaintedString): T =
  try:
    let key = SkPrivateKey.init(utils.fromHex(p)).tryGet()
    # XXX: Here at the moment
    result = crypto.PrivateKey(scheme: Secp256k1, skkey: key)
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type crypto.PrivateKey, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type ValidIpAddress, p: TaintedString): T =
  try:
    result = ValidIpAddress.init(p)
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid IP address")

proc completeCmdArg*(T: type ValidIpAddress, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type Port, p: TaintedString): T =
  try:
    result = Port(parseInt(p))
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid Port number")

proc completeCmdArg*(T: type Port, val: TaintedString): seq[string] =
  return @[]

func defaultListenAddress*(conf: WakuNodeConf): ValidIpAddress =
  # TODO: How should we select between IPv4 and IPv6
  # Maybe there should be a config option for this.
  (static ValidIpAddress.init("0.0.0.0"))
