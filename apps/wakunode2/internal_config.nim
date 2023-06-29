import
  stew/shims/net,
  stew/results,
  libp2p/crypto/crypto
import
  ../../waku/common/utils/nat,
  ../../waku/v2/node/config

proc networkConfiguration*(tcpPort: Port,
                            nat: string,
                            portsShift: uint16,
                            udpPort: Port,
                            dns4DomainName: string,
                            discv5Discovery: bool,
                            discv5UdpPort: Port,
                            extMultiAddrs: seq[string],
                            lightpush: bool,
                            filter: bool,
                            store: bool,
                            relay: bool,
                            listenAddress: ValidIpAddress,
                            websocketPort: Port,
                            websocketSupport: bool,
                            websocketSecureSupport: bool,
                            ): NetConfigResult =

  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport for libp2p traffic.
  let udpPort = tcpPort
  let natRes = setupNat(nat, clientId,
                        Port(uint16(tcpPort) + portsShift),
                        Port(uint16(udpPort) + portsShift))
  if natRes.isErr():
    return err("failed to setup NAT: " & $natRes.error)


  let (extIp, extTcpPort, _) = natRes.get()

  let
    dns4DomainName = if dns4DomainName != "": some(dns4DomainName)
                      else: none(string)

    discv5UdpPort = if discv5Discovery: some(Port(uint16(discv5UdpPort) + portsShift))
                    else: none(Port)

    ## TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
    ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
    ## config, the external port is the same as the bind port.
    extPort = if (extIp.isSome() or dns4DomainName.isSome()) and extTcpPort.isNone():
                some(Port(uint16(tcpPort) + portsShift))
              else:
                extTcpPort
    extMultiAddrs = if (extMultiAddrs.len > 0):
                      let extMultiAddrsValidationRes = validateExtMultiAddrs(extMultiAddrs)
                      if extMultiAddrsValidationRes.isErr():
                        return err("invalid external multiaddress: " & $extMultiAddrsValidationRes.error)

                      else:
                        extMultiAddrsValidationRes.get()
                    else:
                      @[]

    wakuFlags = CapabilitiesBitfield.init(
        lightpush = lightpush,
        filter = filter,
        store = store,
        relay = relay
      )

  # Wrap in none because NetConfig does not have a default constructor
  # TODO: We could change bindIp in NetConfig to be something less restrictive than ValidIpAddress,
  # which doesn't allow default construction
  let netConfigRes = NetConfig.init(
      bindIp = listenAddress,
      bindPort = Port(uint16(tcpPort) + portsShift),
      extIp = extIp,
      extPort = extPort,
      extMultiAddrs = extMultiAddrs,
      wsBindPort = Port(uint16(websocketPort) + portsShift),
      wsEnabled = websocketSupport,
      wssEnabled = websocketSecureSupport,
      dns4DomainName = dns4DomainName,
      discv5UdpPort = discv5UdpPort,
      wakuFlags = some(wakuFlags),
    )

  netConfigRes
