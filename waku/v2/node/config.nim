import
  std/strutils,
  confutils, confutils/defs, confutils/std/net,
  chronicles, chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  nimcrypto/utils,
  eth/keys

type
  WakuNodeConf* = object
    logLevel* {.
      desc: "Sets the log level."
      defaultValue: LogLevel.INFO
      name: "log-level" }: LogLevel

    listenAddress* {.
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

    staticnodes* {.
      desc: "Peer multiaddr to directly connect with. Argument may be repeated."
      name: "staticnode" }: seq[string]

    storenode* {.
      desc: "Peer multiaddr to query for storage.",
      defaultValue: ""
      name: "storenode" }: string

    store* {.
      desc: "Enable store protocol: true|false",
      defaultValue: false
      name: "store" }: bool

    filter* {.
      desc: "Enable filter protocol: true|false",
      defaultValue: false
      name: "filter" }: bool
    
    relay* {.
      desc: "Enable relay protocol: true|false",
      defaultValue: true
      name: "relay" }: bool
    
    rlnrelay* {.
      desc: "Enable spam protection through rln-relay: true|false",
      defaultValue: false
      name: "rlnrelay" }: bool

    swap* {.
      desc: "Enable swap protocol: true|false",
      defaultValue: false
      name: "swap" }: bool

    filternode* {.
      desc: "Peer multiaddr to request content filtering of messages.",
      defaultValue: ""
      name: "filternode" }: string
    
    dbpath* {.
      desc: "The database path for the store protocol.",
      defaultValue: ""
      name: "dbpath" }: string

    topics* {.
      desc: "Default topics to subscribe to (space separated list)."
      defaultValue: "/waku/2/default-waku/proto"
      name: "topics" .}: string

    # NOTE: Signature is different here, we return PrivateKey and not KeyPair
    nodekey* {.
      desc: "P2P node private key as 64 char hex string.",
      defaultValue: crypto.PrivateKey.random(Secp256k1, keys.newRng()[]).tryGet()
      name: "nodekey" }: crypto.PrivateKey

    rpc* {.
      desc: "Enable Waku JSON-RPC server: true|false",
      defaultValue: true
      name: "rpc" }: bool

    rpcAddress* {.
      desc: "Listening address of the JSON-RPC server.",
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "rpc-address" }: ValidIpAddress

    rpcPort* {.
      desc: "Listening port of the JSON-RPC server.",
      defaultValue: 8545
      name: "rpc-port" }: uint16
    
    rpcAdmin* {.
      desc: "Enable access to JSON-RPC Admin API: true|false",
      defaultValue: false
      name: "rpc-admin" }: bool
    
    rpcPrivate* {.
      desc: "Enable access to JSON-RPC Private API: true|false",
      defaultValue: false
      name: "rpc-private" }: bool

    metricsServer* {.
      desc: "Enable the metrics server: true|false"
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
      desc: "Enable metrics logging: true|false"
      defaultValue: false
      name: "log-metrics" }: bool

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
