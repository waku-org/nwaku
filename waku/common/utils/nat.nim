when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[strutils, options],
  chronicles, stew/shims/net as stewNet,
  eth/net/nat

logScope:
  topics = "nat"

proc setupNat*(natConf, clientId: string, tcpPort, udpPort: Port):
    tuple[ip: Option[ValidIpAddress],
          tcpPort: Option[Port],
          udpPort: Option[Port]] {.gcsafe.} =

  var
    endpoint: tuple[ip: Option[ValidIpAddress],
                    tcpPort: Option[Port],
                    udpPort: Option[Port]]
    nat: NatStrategy
  
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
          endpoint.ip = some(ValidIpAddress.init(natConf[6..^1]))
          nat = NatNone
        except ValueError:
          error "not a valid IP address", address = natConf[6..^1]
          quit QuitFailure
      else:
        error "not a valid NAT mechanism", value = natConf
        quit QuitFailure

  if nat != NatNone:
    let extIp = getExternalIP(nat)
    if extIP.isSome:
      endpoint.ip = some(ValidIpAddress.init extIp.get)
      # TODO redirectPorts in considered a gcsafety violation
      # because it obtains the address of a non-gcsafe proc?
      var extPorts: Option[(Port, Port)]
      try:
        extPorts = ({.gcsafe.}:
                    redirectPorts(tcpPort = tcpPort,
                                  udpPort = udpPort,
                                  description = clientId))
      except Exception:
        # @TODO: nat.nim Error: can raise an unlisted exception: Exception. Isolate here for now.
        error "unable to determine external ports"
        extPorts = none((Port, Port))

      if extPorts.isSome:
        let (extTcpPort, extUdpPort) = extPorts.get()
        endpoint.tcpPort = some(extTcpPort)
        endpoint.udpPort = some(extUdpPort)
  
  return endpoint
