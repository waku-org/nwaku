import
  confutils, confutils/defs, confutils/std/net, chronicles, chronos,
  libp2p/crypto/[crypto, secp],
  eth/keys

type
  Chat2MatterbridgeConf* = object
    logLevel* {.
      desc: "Sets the log level"
      defaultValue: LogLevel.INFO
      name: "log-level" .}: LogLevel

    listenAddress* {.
      defaultValue: defaultListenAddress(config)
      desc: "Listening address for the LibP2P traffic"
      name: "listen-address"}: ValidIpAddress

    libp2pTcpPort* {.
      desc: "Libp2p TCP listening port (for Waku v2)"
      defaultValue: 9000
      name: "libp2p-tcp-port" .}: uint16

    udpPort* {.
      desc: "UDP listening port"
      defaultValue: 9000
      name: "udp-port" .}: uint16

    portsShift* {.
      desc: "Add a shift to all default port numbers"
      defaultValue: 0
      name: "ports-shift" .}: uint16

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>"
      defaultValue: "any" .}: string

    rpc* {.
      desc: "Enable Waku RPC server"
      defaultValue: false
      name: "rpc" .}: bool

    rpcAddress* {.
      desc: "Listening address of the RPC server",
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "rpc-address" }: ValidIpAddress

    rpcPort* {.
      desc: "Listening port of the RPC server"
      defaultValue: 8545
      name: "rpc-port" .}: uint16

    metricsServer* {.
      desc: "Enable the metrics server"
      defaultValue: false
      name: "metrics-server" .}: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server"
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "metrics-server-address" }: ValidIpAddress

    metricsServerPort* {.
      desc: "Listening HTTP port of the metrics server"
      defaultValue: 8008
      name: "metrics-server-port" .}: uint16

    ### Waku v2 options
    
    staticnodes* {.
      desc: "Multiaddr of peer to directly connect with. Argument may be repeated"
      name: "staticnode" }: seq[string]

    nodekey* {.
      desc: "P2P node private key as hex"
      defaultValue: crypto.PrivateKey.random(Secp256k1, newRng()[]).tryGet()
      name: "nodekey" }: crypto.PrivateKey

    topics* {.
      desc: "Default topics to subscribe to (space separated list)"
      defaultValue: "/waku/2/default-waku/proto"
      name: "topics" .}: string

    store* {.
      desc: "Flag whether to start store protocol",
      defaultValue: true
      name: "store" }: bool

    filter* {.
      desc: "Flag whether to start filter protocol",
      defaultValue: false
      name: "filter" }: bool

    relay* {.
      desc: "Flag whether to start relay protocol",
      defaultValue: true
      name: "relay" }: bool

    storenode* {.
      desc: "Multiaddr of peer to connect with for waku store protocol"
      defaultValue: ""
      name: "storenode" }: string

    filternode* {.
      desc: "Multiaddr of peer to connect with for waku filter protocol"
      defaultValue: ""
      name: "filternode" }: string
    
    # Matterbridge options    
    mbHostAddress* {.
      desc: "Listening address of the Matterbridge host",
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "mb-host-address" }: ValidIpAddress

    mbHostPort* {.
      desc: "Listening port of the Matterbridge host",
      defaultValue: 4242
      name: "mb-host-port" }: uint16
    
    mbGateway* {.
      desc: "Matterbridge gateway"
      defaultValue: "gateway1"
      name: "mb-gateway" }: string

    ## Chat2 options

    contentTopic* {.
      desc: "Content topic to bridge chat messages to."
      defaultValue: "/waku/2/huilong/proto"
      name: "content-topic" }: string

proc parseCmdArg*(T: type keys.KeyPair, p: TaintedString): T =
  try:
    let privkey = keys.PrivateKey.fromHex(string(p)).tryGet()
    result = privkey.toKeyPair()
  except CatchableError:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type keys.KeyPair, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type crypto.PrivateKey, p: TaintedString): T =
  let key = SkPrivateKey.init(p)
  if key.isOk():
    crypto.PrivateKey(scheme: Secp256k1, skkey: key.get())
  else:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type crypto.PrivateKey, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type ValidIpAddress, p: TaintedString): T =
  try:
    result = ValidIpAddress.init(p)
  except CatchableError:
    raise newException(ConfigurationError, "Invalid IP address")

proc completeCmdArg*(T: type ValidIpAddress, val: TaintedString): seq[string] =
  return @[]

func defaultListenAddress*(conf: Chat2MatterbridgeConf): ValidIpAddress =
  (static ValidIpAddress.init("0.0.0.0"))
