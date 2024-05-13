when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options, strutils, net]
import chronicles, eth/net/nat, stew/results, nativesockets

logScope:
  topics = "nat"

proc setupNat*(
    natConf, clientId: string, tcpPort, udpPort: Port
): Result[
    tuple[ip: Option[IpAddress], tcpPort: Option[Port], udpPort: Option[Port]], string
] {.gcsafe.} =
  let strategy =
    case natConf.toLowerAscii()
    of "any": NatAny
    of "none": NatNone
    of "upnp": NatUpnp
    of "pmp": NatPmp
    else: NatNone

  var endpoint:
    tuple[ip: Option[IpAddress], tcpPort: Option[Port], udpPort: Option[Port]]

  if strategy != NatNone:
    let extIp = getExternalIP(strategy)
    if extIP.isSome():
      endpoint.ip = some(extIp.get())
      # RedirectPorts in considered a gcsafety violation
      # because it obtains the address of a non-gcsafe proc?
      var extPorts: Option[(Port, Port)]
      try:
        extPorts = (
          {.gcsafe.}:
            redirectPorts(tcpPort = tcpPort, udpPort = udpPort, description = clientId)
        )
      except CatchableError:
        # TODO: nat.nim Error: can raise an unlisted exception: Exception. Isolate here for now.
        error "unable to determine external ports"
        extPorts = none((Port, Port))

      if extPorts.isSome():
        let (extTcpPort, extUdpPort) = extPorts.get()
        endpoint.tcpPort = some(extTcpPort)
        endpoint.udpPort = some(extUdpPort)
  else: # NatNone
    if not natConf.startsWith("extip:"):
      return err("not a valid NAT mechanism: " & $natConf)

    try:
      # any required port redirection is assumed to be done by hand
      endpoint.ip = some(parseIpAddress(natConf[6 ..^ 1]))
    except ValueError:
      return err("not a valid IP address: " & $natConf[6 ..^ 1])

  return ok(endpoint)
