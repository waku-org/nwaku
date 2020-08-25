import
  std/strutils,
  chronos,
  eth/net/nat, eth/[p2p, async_utils], eth/p2p/peer_pool

let globalListeningAddr = parseIpAddress("0.0.0.0")

proc setBootNodes*(nodes: openArray[string]): seq[ENode] =
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # TODO: something more user friendly than an expect
    result.add(ENode.fromString(nodeId).expect("correct node"))

proc connectToNodes*(node: EthereumNode, nodes: openArray[string]) =
  for nodeId in nodes:
    # TODO: something more user friendly than an assert
    let whisperENode = ENode.fromString(nodeId).expect("correct node")

    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

proc setupNat*(natConf, clientId: string, tcpPort, udpPort, portsShift: uint16):
    tuple[ip: IpAddress, tcpPort: Port, udpPort: Port] =
  # defaults
  result.ip = globalListeningAddr
  result.tcpPort = Port(tcpPort + portsShift)
  result.udpPort = Port(udpPort + portsShift)

  var nat: NatStrategy
  case natConf.toLowerAscii():
    of "any":
      nat = NatAny
    of "none":
      nat = NatNone
    of "upnp":
      nat = NatUpnp
    of "pmp":
      nat = NatPmp
    else:
      if natConf.startsWith("extip:") and isIpAddress(natConf[6..^1]):
        # any required port redirection is assumed to be done by hand
        result.ip = parseIpAddress(natConf[6..^1])
        nat = NatNone
      else:
        error "not a valid NAT mechanism, nor a valid IP address", value = natConf
        quit(QuitFailure)

  if nat != NatNone:
    let extIP = getExternalIP(nat)
    if extIP.isSome:
      result.ip = extIP.get()
      let extPorts = redirectPorts(tcpPort = result.tcpPort,
                                   udpPort = result.udpPort,
                                   description = clientId)
      if extPorts.isSome:
        (result.tcpPort, result.udpPort) = extPorts.get()
