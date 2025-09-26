import
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/multiaddress,
  libp2p/nameresolving/dnsresolver,
  std/[options, sequtils, net],
  results

import ../common/utils/nat, ../node/net_config, ../waku_enr, ../waku_core, ./waku_conf

proc enrConfiguration*(
    conf: WakuConf, netConfig: NetConfig
): Result[enr.Record, string] =
  var enrBuilder = EnrBuilder.init(conf.nodeKey)

  enrBuilder.withIpAddressAndPorts(
    netConfig.enrIp, netConfig.enrPort, netConfig.discv5UdpPort
  )

  if netConfig.wakuFlags.isSome():
    enrBuilder.withWakuCapabilities(netConfig.wakuFlags.get())

  enrBuilder.withMultiaddrs(netConfig.enrMultiaddrs)

  enrBuilder.withWakuRelaySharding(
    RelayShards(clusterId: conf.clusterId, shardIds: conf.subscribeShards)
  ).isOkOr:
    return err("could not initialize ENR with shards")

  if conf.mixConf.isSome():
    enrBuilder.withMixKey(conf.mixConf.get().mixPubKey)

  let recordRes = enrBuilder.build()
  let record =
    if recordRes.isErr():
      error "failed to create record", error = recordRes.error
      return err($recordRes.error)
    else:
      recordRes.get()

  return ok(record)

proc dnsResolve*(
    domain: string, dnsAddrsNameServers: seq[IpAddress]
): Future[Result[string, string]] {.async.} =
  # Use conf's DNS servers
  var nameServers: seq[TransportAddress]
  for ip in dnsAddrsNameServers:
    nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

  let dnsResolver = DnsResolver.new(nameServers)

  # Resolve domain IP
  let resolved = await dnsResolver.resolveIp(domain, 0.Port, Domain.AF_UNSPEC)

  if resolved.len > 0:
    return ok(resolved[0].host) # Use only first answer
  else:
    return err("Could not resolve IP from DNS: empty response")

# TODO: Reduce number of parameters, can be done once the same is done on Netconfig.init
proc networkConfiguration*(
    clusterId: uint16,
    conf: EndpointConf,
    discv5Conf: Option[Discv5Conf],
    webSocketConf: Option[WebSocketConf],
    wakuFlags: CapabilitiesBitfield,
    dnsAddrsNameServers: seq[IpAddress],
    portsShift: uint16,
    clientId: string,
): Future[NetConfigResult] {.async.} =
  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport for libp2p traffic.
  let natRes = setupNat(
    conf.natStrategy.string,
    clientId,
    Port(uint16(conf.p2pTcpPort) + portsShift),
    Port(uint16(conf.p2pTcpPort) + portsShift),
  )
  if natRes.isErr():
    return err("failed to setup NAT: " & $natRes.error)

  var (extIp, extTcpPort, _) = natRes.get()

  let
    discv5UdpPort =
      if discv5Conf.isSome():
        some(Port(uint16(discv5Conf.get().udpPort) + portsShift))
      else:
        none(Port)

    ## TODO: the NAT setup assumes a manual port mapping configuration if extIp
    ## config is set. This probably implies adding manual config item for
    ## extPort as well. The following heuristic assumes that, in absence of
    ## manual config, the external port is the same as the bind port.
    extPort =
      if (extIp.isSome() or conf.dns4DomainName.isSome()) and extTcpPort.isNone():
        some(Port(uint16(conf.p2pTcpPort) + portsShift))
      else:
        extTcpPort

  # Resolve and use DNS domain IP
  if conf.dns4DomainName.isSome() and extIp.isNone():
    try:
      let dnsRes = await dnsResolve(conf.dns4DomainName.get(), dnsAddrsNameServers)

      if dnsRes.isErr():
        return err($dnsRes.error) # Pass error down the stack

      extIp = some(parseIpAddress(dnsRes.get()))
    except CatchableError:
      return
        err("Could not update extIp to resolved DNS IP: " & getCurrentExceptionMsg())

  let (wsEnabled, wsBindPort, wssEnabled) =
    if webSocketConf.isSome:
      let wsConf = webSocketConf.get()
      (true, some(Port(wsConf.port.uint16 + portsShift)), wsConf.secureConf.isSome)
    else:
      (false, none(Port), false)

  # Wrap in none because NetConfig does not have a default constructor
  # TODO: We could change bindIp in NetConfig to be something less restrictive
  # than IpAddress, which doesn't allow default construction
  let netConfigRes = NetConfig.init(
    clusterId = clusterId,
    bindIp = conf.p2pListenAddress,
    bindPort = Port(uint16(conf.p2pTcpPort) + portsShift),
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = conf.extMultiAddrs,
    extMultiAddrsOnly = conf.extMultiAddrsOnly,
    wsBindPort = wsBindPort,
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    dns4DomainName = conf.dns4DomainName,
    discv5UdpPort = discv5UdpPort,
    wakuFlags = some(wakuFlags),
    dnsNameServers = dnsAddrsNameServers,
  )

  return netConfigRes
