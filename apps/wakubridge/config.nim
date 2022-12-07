import
  stew/results,
  chronos,
  confutils,
  confutils/defs,
  confutils/std/net,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  eth/keys

import
  ../../waku/common/logging


type ConfResult*[T] = Result[T, string]

type
  FleetV1* =  enum
    none
    prod
    staging
    test

  WakuBridgeConf* = object
    ## Log configuration
    logLevel* {.
      desc: "Sets the log level for process. Supported levels: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL",
      defaultValue: logging.LogLevel.INFO,
      name: "log-level" .}: logging.LogLevel

    logFormat* {.
      desc: "Specifies what kind of logs should be written to stdout. Suported formats: Text, JSON",
      defaultValue: logging.LogFormat.Text,
      name: "log-format" .}: logging.LogFormat

    ## General node config
    listenAddress* {.
      defaultValue: defaultListenAddress()
      desc: "Listening address for the LibP2P traffic"
      name: "listen-address"}: ValidIpAddress

    libp2pTcpPort* {.
      desc: "Libp2p TCP listening port (for Waku v2)"
      defaultValue: 9000
      name: "libp2p-tcp-port" .}: uint16

    devp2pTcpPort* {.
      desc: "Devp2p TCP listening port (for Waku v1)"
      defaultValue: 30303
      name: "devp2p-tcp-port" .}: uint16

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

    ### Waku v1 options

    fleetV1* {.
      desc: "Select the Waku v1 fleet to connect to"
      defaultValue: FleetV1.none
      name: "fleet-v1" .}: FleetV1

    staticnodesV1* {.
      desc: "Enode URL to directly connect with. Argument may be repeated"
      name: "staticnode-v1" .}: seq[string]

    nodekeyV1* {.
      desc: "DevP2P node private key as hex",
      # TODO: can the rng be passed in somehow via Load?
      defaultValue: keys.KeyPair.random(keys.newRng()[])
      name: "nodekey-v1" .}: keys.KeyPair

    wakuV1Pow* {.
      desc: "PoW requirement of Waku v1 node.",
      defaultValue: 0.002
      name: "waku-v1-pow" .}: float64

    wakuV1TopicInterest* {.
      desc: "Run as Waku v1 node with a topic-interest",
      defaultValue: false
      name: "waku-v1-topic-interest" .}: bool

    ### Waku v2 options

    staticnodesV2* {.
      desc: "Multiaddr of peer to directly connect with. Argument may be repeated"
      name: "staticnode-v2" }: seq[string]

    nodekeyV2* {.
      desc: "P2P node private key as hex"
      defaultValue: crypto.PrivateKey.random(Secp256k1, crypto.newRng()[]).tryGet()
      name: "nodekey-v2" }: crypto.PrivateKey

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

    dnsAddrs* {.
      desc: "Enable resolution of `dnsaddr`, `dns4` or `dns6` multiaddrs"
      defaultValue: true
      name: "dns-addrs" }: bool

    dnsAddrsNameServers* {.
      desc: "DNS name server IPs to query for DNS multiaddrs resolution. Argument may be repeated."
      defaultValue: @[ValidIpAddress.init("1.1.1.1"), ValidIpAddress.init("1.0.0.1")]
      name: "dns-addrs-name-server" }: seq[ValidIpAddress]

    ### Bridge options

    bridgePubsubTopic* {.
      desc: "Waku v2 Pubsub topic to bridge to/from"
      defaultValue: "/waku/2/default-waku/proto"
      name: "bridge-pubsub-topic" }: string


proc parseCmdArg*(T: type keys.KeyPair, p: string): T =
  try:
    let privkey = keys.PrivateKey.fromHex(p).tryGet()
    result = privkey.toKeyPair()
  except CatchableError:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type keys.KeyPair, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type crypto.PrivateKey, p: string): T =
  let key = SkPrivateKey.init(p)
  if key.isOk():
    crypto.PrivateKey(scheme: Secp256k1, skkey: key.get())
  else:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type crypto.PrivateKey, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type ValidIpAddress, p: string): T =
  try:
    result = ValidIpAddress.init(p)
  except CatchableError:
    raise newException(ConfigurationError, "Invalid IP address")

proc completeCmdArg*(T: type ValidIpAddress, val: string): seq[string] =
  return @[]

func defaultListenAddress*(): ValidIpAddress =
  (static ValidIpAddress.init("0.0.0.0"))



## Load

{.push warning[ProveInit]: off.}

proc load*(T: type WakuBridgeConf, version=""): ConfResult[T] =
  try:
    let conf = confutils.load(WakuBridgeConf, version=version)
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

{.pop.}
