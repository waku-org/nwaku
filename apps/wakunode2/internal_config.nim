import
  std/options,
  stew/shims/net,
  stew/results,
  libp2p/crypto/crypto,
  libp2p/multiaddress
import
  ../../waku/common/utils/nat,
  ../../waku/v2/node/config,
  ../../waku/v2/waku_enr/capabilities,
  ./external_config

proc validateExtMultiAddrs*(vals: seq[string]):
                            Result[seq[MultiAddress], string] =
  var multiaddrs: seq[MultiAddress]
  for val in vals:
    let multiaddr = ? MultiAddress.init(val)
    multiaddrs.add(multiaddr)
  return ok(multiaddrs)

proc networkConfiguration*(conf: WakuNodeConf,
                           clientId: string,
                           ): NetConfigResult =

  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport for libp2p traffic.
  let natRes = setupNat(conf.nat, clientId,
                        Port(uint16(conf.tcpPort) + conf.portsShift),
                        Port(uint16(conf.tcpPort) + conf.portsShift))
  if natRes.isErr():
    return err("failed to setup NAT: " & $natRes.error)

  let (extIp, extTcpPort, _) = natRes.get()

  let
    dns4DomainName = if conf.dns4DomainName != "": some(conf.dns4DomainName)
                     else: none(string)

    discv5UdpPort = if conf.discv5Discovery:
                      some(Port(uint16(conf.discv5UdpPort) + conf.portsShift))
                    else: none(Port)

    ## TODO: the NAT setup assumes a manual port mapping configuration if extIp
    ## config is set. This probably implies adding manual config item for
    ## extPort as well. The following heuristic assumes that, in absence of
    ## manual config, the external port is the same as the bind port.

    extPort = if (extIp.isSome() or dns4DomainName.isSome()) and
                extTcpPort.isNone():
                some(Port(uint16(conf.tcpPort) + conf.portsShift))
              else:
                extTcpPort

    extMultiAddrs = if (conf.extMultiAddrs.len > 0):
                      let extMultiAddrsValidationRes =
                          validateExtMultiAddrs(conf.extMultiAddrs)
                      if extMultiAddrsValidationRes.isErr():
                        return err("invalid external multiaddress: " &
                                   $extMultiAddrsValidationRes.error)
                      else:
                        extMultiAddrsValidationRes.get()
                    else:
                      @[]

    wakuFlags = CapabilitiesBitfield.init(
        lightpush = conf.lightpush,
        filter = conf.filter,
        store = conf.store,
        relay = conf.relay
      )

  # Wrap in none because NetConfig does not have a default constructor
  # TODO: We could change bindIp in NetConfig to be something less restrictive
  # than ValidIpAddress, which doesn't allow default construction
  let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = Port(uint16(conf.tcpPort) + conf.portsShift),
      extIp = extIp,
      extPort = extPort,
      extMultiAddrs = extMultiAddrs,
      wsBindPort = Port(uint16(conf.websocketPort) + conf.portsShift),
      wsEnabled = conf.websocketSupport,
      wssEnabled = conf.websocketSecureSupport,
      dns4DomainName = dns4DomainName,
      discv5UdpPort = discv5UdpPort,
      wakuFlags = some(wakuFlags),
    )

  return netConfigRes
