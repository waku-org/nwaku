import
  std/[strutils, options],
  chronicles, stew/shims/net as stewNet,
  eth/net/nat

proc setupNat*(natConf, clientId: string, tcpPort, udpPort: Port):
    tuple[ip: Option[ValidIpAddress], tcpPort: Option[Port],
      udpPort: Option[Port]] {.gcsafe.} =

  var nat: NatStrategy
  case natConf.toLowerAscii:
    of "any":
      nat = NatAny
    of "none":
      nat = NatNone
    of "upnp":
      nat = NatUpnp
    of "pmp":
      nat = NatPmp
    else:
      if natConf.startsWith("extip:"):
        try:
          # any required port redirection is assumed to be done by hand
          result.ip = some(ValidIpAddress.init(natConf[6..^1]))
          nat = NatNone
        except ValueError:
          error "nor a valid IP address", address = natConf[6..^1]
          quit QuitFailure
      else:
        error "not a valid NAT mechanism", value = natConf
        quit QuitFailure

  if nat != NatNone:
    let extIp = getExternalIP(nat)
    if extIP.isSome:
      result.ip = some(ValidIpAddress.init extIp.get)
      # TODO redirectPorts in considered a gcsafety violation
      # because it obtains the address of a non-gcsafe proc?
      let extPorts = ({.gcsafe.}:
        redirectPorts(tcpPort = tcpPort,
                      udpPort = udpPort,
                      description = clientId))
      if extPorts.isSome:
        let (extTcpPort, extUdpPort) = extPorts.get()
        result.tcpPort = some(extTcpPort)
        result.udpPort = some(extUdpPort)
