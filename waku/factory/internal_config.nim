import
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  libp2p/nameresolving/dnsresolver,
  std/[options, sequtils, strutils, net],
  results
import
  ./external_config,
  ../common/utils/nat,
  ../node/net_config,
  ../waku_enr/capabilities,
  ../waku_enr,
  ../waku_core,
  ./waku_conf

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
    RelayShards(clusterId: conf.clusterId, shardIds: conf.shards)
  ).isOkOr:
    return err("could not initialize ENR with shards")

  let recordRes = enrBuilder.build()
  let record =
    if recordRes.isErr():
      error "failed to create record", error = recordRes.error
      return err($recordRes.error)
    else:
      recordRes.get()

  return ok(record)

proc dnsResolve*(
    domain: DomainName, conf: WakuConf
): Future[Result[string, string]] {.async.} =
  # Use conf's DNS servers
  var nameServers: seq[TransportAddress]
  for ip in conf.dnsAddrsNameServers:
    nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

  let dnsResolver = DnsResolver.new(nameServers)

  # Resolve domain IP
  let resolved = await dnsResolver.resolveIp(domain.string, 0.Port, Domain.AF_UNSPEC)

  if resolved.len > 0:
    return ok(resolved[0].host) # Use only first answer
  else:
    return err("Could not resolve IP from DNS: empty response")

proc networkConfiguration*(conf: WakuConf, clientId: string): NetConfigResult =
  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport for libp2p traffic.
  let natRes = setupNat(
    conf.natStrategy.string,
    clientId,
    Port(uint16(conf.p2pTcpPort) + conf.portsShift),
    Port(uint16(conf.p2pTcpPort) + conf.portsShift),
  )
  if natRes.isErr():
    return err("failed to setup NAT: " & $natRes.error)

  var (extIp, extTcpPort, _) = natRes.get()

  let
    discv5UdpPort =
      if conf.discv5Conf.isSome:
        some(Port(uint16(conf.discv5Conf.get().udpPort) + conf.portsShift))
      else:
        none(Port)

    ## TODO: the NAT setup assumes a manual port mapping configuration if extIp
    ## config is set. This probably implies adding manual config item for
    ## extPort as well. The following heuristic assumes that, in absence of
    ## manual config, the external port is the same as the bind port.
    extPort =
      if (extIp.isSome() or conf.dns4DomainName.isSome()) and extTcpPort.isNone():
        some(Port(uint16(conf.p2pTcpPort) + conf.portsShift))
      else:
        extTcpPort

    wakuFlags = CapabilitiesBitfield.init(
      lightpush = conf.lightpush,
      filter = conf.filter,
      store = conf.store,
      relay = conf.relay,
      sync = conf.storeSync,
    )

  # Resolve and use DNS domain IP
  if conf.dns4DomainName.isSome() and extIp.isNone():
    try:
      let dnsRes = waitFor dnsResolve(conf.dns4DomainName.get(), conf)

      if dnsRes.isErr():
        return err($dnsRes.error) # Pass error down the stack

      extIp = some(parseIpAddress(dnsRes.get()))
    except CatchableError:
      return
        err("Could not update extIp to resolved DNS IP: " & getCurrentExceptionMsg())

  let (wsEnabled, wsBindPort, wssEnabled) =
    if conf.webSocketConf.isSome:
      let webSocketConf = conf.webSocketConf.get()
      (
        true,
        some(Port(webSocketConf.port.uint16 + conf.portsShift)),
        webSocketConf.secureConf.isSome,
      )
    else:
      (false, none(Port), false)

  # Wrap in none because NetConfig does not have a default constructor
  # TODO: We could change bindIp in NetConfig to be something less restrictive
  # than IpAddress, which doesn't allow default construction
  let netConfigRes = NetConfig.init(
    clusterId = conf.clusterId,
    bindIp = conf.p2pListenAddress,
    bindPort = Port(uint16(conf.p2pTcpPort) + conf.portsShift),
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = conf.extMultiAddrs,
    extMultiAddrsOnly = conf.extMultiAddrsOnly,
    wsBindPort = wsBindPort,
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    dns4DomainName = conf.dns4DomainName.map(
      proc(dn: DomainName): string =
        dn.string
    ),
    discv5UdpPort = discv5UdpPort,
    wakuFlags = some(wakuFlags),
  )

  return netConfigRes

# TODO: redefine in the right place
# proc applyPresetConfiguration*(
#     srcConf: WakuNodeConf, wakuConfBuilder: var WakuConfBuilder
# ): void =
#   var preset = srcConf.preset

#   if srcConf.clusterId == 1:
#     warn(
#       "TWN - The Waku Network configuration will not be applied when `--cluster-id=1` is passed in future releases. Use `--preset=twn` instead."
#     )
#     preset = "twn"

#   case toLowerAscii(preset)
#   of "twn":
#     let twnClusterConf = ClusterConf.TheWakuNetworkConf()

#     wakuConfBuilder.withClusterConf(twnClusterConf)
#   else:
#     discard

# TODO: numShardsInNetwork should be mandatory with autosharding, and unneeded otherwise
proc getNumShardsInNetwork*(conf: WakuNodeConf): uint32 =
  if conf.numShardsInNetwork != 0:
    return conf.numShardsInNetwork
  # If conf.numShardsInNetwork is not set, use 1024 - the maximum possible as per the static sharding spec
  # https://github.com/waku-org/specs/blob/master/standards/core/relay-sharding.md#static-sharding
  return uint32(MaxShardIndex + 1)
