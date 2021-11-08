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
    test
  
  Chat2Conf* = object
    ## General node config

    logLevel* {.
      desc: "Sets the log level."
      defaultValue: LogLevel.INFO
      name: "log-level" }: LogLevel
    
    nodekey* {.
      desc: "P2P node private key as 64 char hex string.",
      defaultValue: crypto.PrivateKey.random(Secp256k1, keys.newRng()[]).tryGet()
      name: "nodekey" }: crypto.PrivateKey

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
    
    ## Persistence config
    
    dbPath* {.
      desc: "The database path for peristent storage",
      defaultValue: ""
      name: "db-path" }: string
    
    persistPeers* {.
      desc: "Enable peer persistence: true|false",
      defaultValue: false
      name: "persist-peers" }: bool
    
    persistMessages* {.
      desc: "Enable message persistence: true|false",
      defaultValue: false
      name: "persist-messages" }: bool

    ## Relay config
    
    relay* {.
      desc: "Enable relay protocol: true|false",
      defaultValue: true
      name: "relay" }: bool
    
    rlnRelay* {.
      desc: "Enable spam protection through rln-relay: true|false",
      defaultValue: false
      name: "rln-relay" }: bool
    
    staticnodes* {.
      desc: "Peer multiaddr to directly connect with. Argument may be repeated."
      name: "staticnode" }: seq[string]
    
    keepAlive* {.
      desc: "Enable keep-alive for idle connections: true|false",
      defaultValue: false
      name: "keep-alive" }: bool

    topics* {.
      desc: "Default topics to subscribe to (space separated list)."
      defaultValue: "/waku/2/default-waku/proto"
      name: "topics" .}: string

    ## Store config

    store* {.
      desc: "Enable store protocol: true|false",
      defaultValue: true
      name: "store" }: bool

    storenode* {.
      desc: "Peer multiaddr to query for storage.",
      defaultValue: ""
      name: "storenode" }: string
    
    ## Filter config

    filter* {.
      desc: "Enable filter protocol: true|false",
      defaultValue: false
      name: "filter" }: bool
    
    filternode* {.
      desc: "Peer multiaddr to request content filtering of messages.",
      defaultValue: ""
      name: "filternode" }: string
    
    ## Swap config

    swap* {.
      desc: "Enable swap protocol: true|false",
      defaultValue: true
      name: "swap" }: bool
    
    ## Lightpush config

    lightpush* {.
      desc: "Enable lightpush protocol: true|false",
      defaultValue: false
      name: "lightpush" }: bool
    
    lightpushnode* {.
      desc: "Peer multiaddr to request lightpush of published messages.",
      defaultValue: ""
      name: "lightpushnode" }: string
    
    ## JSON-RPC config

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
    
    ## Metrics config

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

    metricsLogging* {.
      desc: "Enable metrics logging: true|false"
      defaultValue: false
      name: "metrics-logging" }: bool
    
    ## DNS discovery config
    
    dnsDiscovery* {.
      desc: "Enable discovering nodes via DNS"
      defaultValue: false
      name: "dns-discovery" }: bool
    
    dnsDiscoveryUrl* {.
      desc: "URL for DNS node list in format 'enrtree://<key>@<fqdn>'",
      defaultValue: ""
      name: "dns-discovery-url" }: string
    
    dnsDiscoveryNameServers* {.
      desc: "DNS name server IPs to query. Argument may be repeated."
      defaultValue: @[ValidIpAddress.init("1.1.1.1"), ValidIpAddress.init("1.0.0.1")]
      name: "dns-discovery-name-server" }: seq[ValidIpAddress]

    ## Chat2 configuration
    
    fleet* {.
      desc: "Select the fleet to connect to."
      defaultValue: Fleet.prod
      name: "fleet" }: Fleet

    contentTopic* {.
      desc: "Content topic for chat messages."
      defaultValue: "/toy-chat/2/huilong/proto"
      name: "content-topic" }: string

    ## Websocket Configuration
    websocketSupport* {.
      desc: "Enable websocket:  true|false",
      defaultValue: false
      name: "websocket-support"}: bool
    
    websocketPort* {.
      desc: "WebSocket listening port."
      defaultValue: 8000
      name: "websocket-port" }: Port
    
    websocketSecureSupport* {.
      desc: "WebSocket Secure Support."
      defaultValue: false
      name: "websocket-secure-support" }: bool

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

func defaultListenAddress*(conf: Chat2Conf): ValidIpAddress =
  # TODO: How should we select between IPv4 and IPv6
  # Maybe there should be a config option for this.
  (static ValidIpAddress.init("0.0.0.0"))
