import
  confutils/defs, chronicles, chronos, eth/keys

type
  WakuNodeCmd* = enum
    noCommand

  WakuNodeConf* = object
    logLevel* {.
      desc: "Sets the log level."
      defaultValue: LogLevel.INFO
      name: "log-level" .}: LogLevel

    case cmd* {.
      command
      defaultValue: noCommand .}: WakuNodeCmd

    of noCommand:
      tcpPort* {.
        desc: "TCP listening port."
        defaultValue: 30303
        name: "tcp-port" .}: uint16

      udpPort* {.
        desc: "UDP listening port."
        defaultValue: 30303
        name: "udp-port" .}: uint16

      portsShift* {.
        desc: "Add a shift to all port numbers."
        defaultValue: 0
        name: "ports-shift" .}: uint16

      nat* {.
        desc: "Specify method to use for determining public address. " &
              "Must be one of: any, none, upnp, pmp, extip:<IP>."
        defaultValue: "any" .}: string

      staticnodes* {.
        desc: "Enode URL to directly connect with. Argument may be repeated."
        name: "staticnode" .}: seq[string]

      nodekey* {.
        desc: "P2P node private key as hex.",
        defaultValue: KeyPair.random(keys.newRng()[])
        name: "nodekey" .}: KeyPair

proc parseCmdArg*(T: type KeyPair, p: TaintedString): T =
  try:
    let privkey = PrivateKey.fromHex(string(p)).tryGet()
    result = privkey.toKeyPair()
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type KeyPair, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type IpAddress, p: TaintedString): T =
  try:
    result = parseIpAddress(p)
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid IP address")

proc completeCmdArg*(T: type IpAddress, val: TaintedString): seq[string] =
  return @[]
