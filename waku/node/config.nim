when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, sequtils, strutils],
  stew/results,
  stew/shims/net,
  libp2p/multiaddress
import
   ../../waku/waku_core/peers
import
  ../waku_enr


type NetConfig* = object
  hostAddress*: MultiAddress
  wsHostAddress*: Option[MultiAddress]
  hostExtAddress*: Option[MultiAddress]
  wsExtAddress*: Option[MultiAddress]
  wssEnabled*: bool
  extIp*: Option[ValidIpAddress]
  extPort*: Option[Port]
  dns4DomainName*: Option[string]
  announcedAddresses*: seq[MultiAddress]
  extMultiAddrs*: seq[MultiAddress]
  enrMultiAddrs*: seq[MultiAddress]
  enrIp*: Option[ValidIpAddress]
  enrPort*: Option[Port]
  discv5UdpPort*: Option[Port]
  wakuFlags*: Option[CapabilitiesBitfield]
  bindIp*: ValidIpAddress
  bindPort*: Port

type NetConfigResult* = Result[NetConfig, string]


template ip4TcpEndPoint(address, port): MultiAddress =
  MultiAddress.init(address, tcpProtocol, port)

template dns4Ma(dns4DomainName: string): MultiAddress =
  MultiAddress.init("/dns4/" & dns4DomainName).tryGet()

template tcpPortMa(port: Port): MultiAddress =
  MultiAddress.init("/tcp/" & $port).tryGet()

template dns4TcpEndPoint(dns4DomainName: string, port: Port): MultiAddress =
  dns4Ma(dns4DomainName) & tcpPortMa(port)

template wsFlag(wssEnabled: bool): MultiAddress =
  if wssEnabled: MultiAddress.init("/wss").tryGet()
  else: MultiAddress.init("/ws").tryGet()


proc formatListenAddress(inputMultiAdd: MultiAddress): MultiAddress =
    let inputStr = $inputMultiAdd
    # If MultiAddress contains "0.0.0.0", replace it for "127.0.0.1"
    return MultiAddress.init(inputStr.replace("0.0.0.0", "127.0.0.1")).get()

proc init*(T: type NetConfig,
    bindIp: ValidIpAddress,
    bindPort: Port,
    extIp = none(ValidIpAddress),
    extPort = none(Port),
    extMultiAddrs = newSeq[MultiAddress](),
    wsBindPort: Port = Port(8000),
    wsEnabled: bool = false,
    wssEnabled: bool = false,
    dns4DomainName = none(string),
    discv5UdpPort = none(Port),
    wakuFlags = none(CapabilitiesBitfield)): NetConfigResult =
  ## Initialize and validate waku node network configuration

  # Bind addresses
  let hostAddress = ip4TcpEndPoint(bindIp, bindPort)

  var wsHostAddress = none(MultiAddress)
  if wsEnabled or wssEnabled:
    try:
      wsHostAddress = some(ip4TcpEndPoint(bindIp, wsbindPort) & wsFlag(wssEnabled))
    except CatchableError:
      return err(getCurrentExceptionMsg())

  let enrIp = if extIp.isSome(): extIp else: some(bindIp)
  let enrPort = if extPort.isSome(): extPort else: some(bindPort)

  # Setup external addresses, if available
  var hostExtAddress, wsExtAddress = none(MultiAddress)

  if dns4DomainName.isSome():
    # Use dns4 for externally announced addresses
    try:
      hostExtAddress = some(dns4TcpEndPoint(dns4DomainName.get(), extPort.get()))
    except CatchableError:
      return err(getCurrentExceptionMsg())

    if wsHostAddress.isSome():
      try:
        wsExtAddress = some(dns4TcpEndPoint(dns4DomainName.get(), wsBindPort) & wsFlag(wssEnabled))
      except CatchableError:
        return err(getCurrentExceptionMsg())
  else:
    # No public domain name, use ext IP if available
    if extIp.isSome() and extPort.isSome():
      hostExtAddress = some(ip4TcpEndPoint(extIp.get(), extPort.get()))

      if wsHostAddress.isSome():
        try:
          wsExtAddress = some(ip4TcpEndPoint(extIp.get(), wsBindPort) & wsFlag(wssEnabled))
        except CatchableError:
          return err(getCurrentExceptionMsg())

  var announcedAddresses = newSeq[MultiAddress]()

  if hostExtAddress.isSome():
    announcedAddresses.add(hostExtAddress.get())
  else:
    announcedAddresses.add(formatListenAddress(hostAddress)) # We always have at least a bind address for the host

  # External multiaddrs that the operator may have configured
  if extMultiAddrs.len > 0:
    announcedAddresses.add(extMultiAddrs)

  if wsExtAddress.isSome():
    announcedAddresses.add(wsExtAddress.get())
  elif wsHostAddress.isSome():
    announcedAddresses.add(wsHostAddress.get())

  let
    # enrMultiaddrs are just addresses which cannot be represented in ENR, as described in
    # https://rfc.vac.dev/spec/31/#many-connection-types
    enrMultiaddrs = announcedAddresses.filterIt(it.hasProtocol("dns4") or
                                                it.hasProtocol("dns6") or
                                                it.hasProtocol("ws") or
                                                it.hasProtocol("wss"))

  ok(NetConfig(
    hostAddress: hostAddress,
    wsHostAddress: wsHostAddress,
    hostExtAddress: hostExtAddress,
    wsExtAddress: wsExtAddress,
    extIp: extIp,
    extPort: extPort,
    wssEnabled: wssEnabled,
    dns4DomainName: dns4DomainName,
    announcedAddresses: announcedAddresses,
    extMultiAddrs: extMultiAddrs,
    enrMultiaddrs: enrMultiaddrs,
    enrIp: enrIp,
    enrPort: enrPort,
    discv5UdpPort: discv5UdpPort,
    bindIp: bindIp,
    bindPort: bindPort,
    wakuFlags: wakuFlags
  ))
