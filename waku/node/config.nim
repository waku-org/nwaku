import
  confutils/defs, chronicles, chronos, eth/keys

type
  FleetV1* =  enum
    none
    prod
    staging
    test

  WakuNodeConf* = object
    logLevel* {.
      desc: "Sets the log level."
      defaultValue: LogLevel.INFO
      name: "log-level" .}: LogLevel

    libp2pTcpPort* {.
      desc: "Libp2p TCP listening port (for Waku v2)."
      defaultValue: 9000
      name: "libp2p-tcp-port" .}: uint16

    devp2pTcpPort* {.
      desc: "Devp2p TCP listening port (for Waku v1)."
      defaultValue: 30303
      name: "devp2p-tcp-port" .}: uint16

    udpPort* {.
      desc: "UDP listening port."
      defaultValue: 9000
      name: "udp-port" .}: uint16

    portsShift* {.
      desc: "Add a shift to all default port numbers."
      defaultValue: 0
      name: "ports-shift" .}: uint16

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>."
      defaultValue: "any" .}: string

    rpc* {.
      desc: "Enable Waku RPC server.",
      defaultValue: false
      name: "rpc" .}: bool

    rpcAddress* {.
      desc: "Listening address of the RPC server.",
      defaultValue: parseIpAddress("127.0.0.1")
      name: "rpc-address" .}: IpAddress

    rpcPort* {.
      desc: "Listening port of the RPC server.",
      defaultValue: 8545
      name: "rpc-port" .}: uint16

    metricsServer* {.
      desc: "Enable the metrics server."
      defaultValue: false
      name: "metrics-server" .}: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server."
      defaultValue: parseIpAddress("127.0.0.1")
      name: "metrics-server-address" .}: IpAddress

    metricsServerPort* {.
      desc: "Listening HTTP port of the metrics server."
      defaultValue: 8008
      name: "metrics-server-port" .}: uint16

    ### Waku v1 options
    fleetv1* {.
      desc: "Select the Waku v1 fleet to connect to."
      defaultValue: FleetV1.none
      name: "fleetv1" .}: FleetV1

    staticnodes* {.
      desc: "Enode URL to directly connect with. Argument may be repeated."
      name: "staticnode" .}: seq[string]

    nodekey* {.
      desc: "DevP2P node private key as hex.",
      # TODO: can the rng be passed in somehow via Load?
      defaultValue: KeyPair.random(keys.newRng()[])
      name: "nodekey" .}: KeyPair

proc parseCmdArg*(T: type KeyPair, p: TaintedString): T =
  try:
    let privkey = PrivateKey.fromHex(string(p)).tryGet()
    result = privkey.toKeyPair()
  except CatchableError:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type KeyPair, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type IpAddress, p: TaintedString): T =
  try:
    result = parseIpAddress(p)
  except CatchableError:
    raise newException(ConfigurationError, "Invalid IP address")

proc completeCmdArg*(T: type IpAddress, val: TaintedString): seq[string] =
  return @[]
