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
  ../node/config,
  ../waku_enr/capabilities,
  ../waku_enr,
  ../waku_core,
  ./networks_config

proc enrConfiguration*(
    conf: WakuNodeConf, netConfig: NetConfig, key: crypto.PrivateKey
): Result[enr.Record, string] =
  var enrBuilder = EnrBuilder.init(key)

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

proc validateExtMultiAddrs*(vals: seq[string]): Result[seq[MultiAddress], string] =
  var multiaddrs: seq[MultiAddress]
  for val in vals:
    let multiaddr = ?MultiAddress.init(val)
    multiaddrs.add(multiaddr)
  return ok(multiaddrs)

proc dnsResolve*(
    domain: string, conf: WakuNodeConf
): Future[Result[string, string]] {.async.} =
  # Use conf's DNS servers
  var nameServers: seq[TransportAddress]
  for ip in conf.dnsAddrsNameServers:
    nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

  let dnsResolver = DnsResolver.new(nameServers)

  # Resolve domain IP
  let resolved = await dnsResolver.resolveIp(domain, 0.Port, Domain.AF_UNSPEC)

  if resolved.len > 0:
    return ok(resolved[0].host) # Use only first answer
  else:
    return err("Could not resolve IP from DNS: empty response")

proc networkConfiguration*(conf: WakuNodeConf, clientId: string): NetConfigResult =
  ## `udpPort` is only supplied to satisfy underlying APIs but is not
  ## actually a supported transport for libp2p traffic.
  let natRes = setupNat(
    conf.nat,
    clientId,
    Port(uint16(conf.tcpPort) + conf.portsShift),
    Port(uint16(conf.tcpPort) + conf.portsShift),
  )
  if natRes.isErr():
    return err("failed to setup NAT: " & $natRes.error)

  var (extIp, extTcpPort, _) = natRes.get()

  let
    dns4DomainName =
      if conf.dns4DomainName != "":
        some(conf.dns4DomainName)
      else:
        none(string)

    discv5UdpPort =
      if conf.discv5Discovery:
        some(Port(uint16(conf.discv5UdpPort) + conf.portsShift))
      else:
        none(Port)

    ## TODO: the NAT setup assumes a manual port mapping configuration if extIp
    ## config is set. This probably implies adding manual config item for
    ## extPort as well. The following heuristic assumes that, in absence of
    ## manual config, the external port is the same as the bind port.
    extPort =
      if (extIp.isSome() or dns4DomainName.isSome()) and extTcpPort.isNone():
        some(Port(uint16(conf.tcpPort) + conf.portsShift))
      else:
        extTcpPort

    extMultiAddrs =
      if (conf.extMultiAddrs.len > 0):
        let extMultiAddrsValidationRes = validateExtMultiAddrs(conf.extMultiAddrs)
        if extMultiAddrsValidationRes.isErr():
          return
            err("invalid external multiaddress: " & $extMultiAddrsValidationRes.error)
        else:
          extMultiAddrsValidationRes.get()
      else:
        @[]

    wakuFlags = CapabilitiesBitfield.init(
      lightpush = conf.lightpush,
      filter = conf.filter,
      store = conf.store,
      relay = conf.relay,
      sync = conf.storeSync,
    )

  # Resolve and use DNS domain IP
  if dns4DomainName.isSome() and extIp.isNone():
    try:
      let dnsRes = waitFor dnsResolve(conf.dns4DomainName, conf)

      if dnsRes.isErr():
        return err($dnsRes.error) # Pass error down the stack

      extIp = some(parseIpAddress(dnsRes.get()))
    except CatchableError:
      return
        err("Could not update extIp to resolved DNS IP: " & getCurrentExceptionMsg())

  # Wrap in none because NetConfig does not have a default constructor
  # TODO: We could change bindIp in NetConfig to be something less restrictive
  # than IpAddress, which doesn't allow default construction
  let netConfigRes = NetConfig.init(
    clusterId = conf.clusterId,
    bindIp = conf.listenAddress,
    bindPort = Port(uint16(conf.tcpPort) + conf.portsShift),
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = extMultiAddrs,
    extMultiAddrsOnly = conf.extMultiAddrsOnly,
    wsBindPort = Port(uint16(conf.websocketPort) + conf.portsShift),
    wsEnabled = conf.websocketSupport,
    wssEnabled = conf.websocketSecureSupport,
    dns4DomainName = dns4DomainName,
    discv5UdpPort = discv5UdpPort,
    wakuFlags = some(wakuFlags),
    dnsNameServers = conf.dnsAddrsNameServers,
  )

  return netConfigRes

proc applyPresetConfiguration*(srcConf: WakuNodeConf): Result[WakuNodeConf, string] =
  var resConf = srcConf

  if resConf.clusterId == 1:
    warn(
      "TWN - The Waku Network configuration will not be applied when `--cluster-id=1` is passed in future releases. Use `--preset=twn` instead."
    )
    resConf.preset = "twn"

  case toLowerAscii(resConf.preset)
  of "twn":
    let twnClusterConf = ClusterConf.TheWakuNetworkConf()

    # Override configuration
    resConf.maxMessageSize = twnClusterConf.maxMessageSize
    resConf.clusterId = twnClusterConf.clusterId
    resConf.rlnRelay = twnClusterConf.rlnRelay
    resConf.rlnRelayEthContractAddress = twnClusterConf.rlnRelayEthContractAddress
    resConf.rlnRelayChainId = twnClusterConf.rlnRelayChainId
    resConf.rlnRelayDynamic = twnClusterConf.rlnRelayDynamic
    resConf.rlnRelayBandwidthThreshold = twnClusterConf.rlnRelayBandwidthThreshold
    resConf.discv5Discovery = twnClusterConf.discv5Discovery
    resConf.discv5BootstrapNodes =
      resConf.discv5BootstrapNodes & twnClusterConf.discv5BootstrapNodes
    resConf.rlnEpochSizeSec = twnClusterConf.rlnEpochSizeSec
    resConf.rlnRelayUserMessageLimit = twnClusterConf.rlnRelayUserMessageLimit
    resConf.numShardsInNetwork = twnClusterConf.numShardsInNetwork

    if resConf.relay:
      resConf.rlnRelay = twnClusterConf.rlnRelay
  else:
    discard

  return ok(resConf)

# TODO: numShardsInNetwork should be mandatory with autosharding, and unneeded otherwise
proc getNumShardsInNetwork*(conf: WakuNodeConf): uint32 =
  if conf.numShardsInNetwork != 0:
    return conf.numShardsInNetwork
  # If conf.numShardsInNetwork is not set, use 1024 - the maximum possible as per the static sharding spec
  # https://github.com/waku-org/specs/blob/master/standards/core/relay-sharding.md#static-sharding
  return uint32(MaxShardIndex + 1)

proc validateShards*(conf: WakuNodeConf): Result[void, string] =
  let numShardsInNetwork = getNumShardsInNetwork(conf)

  for shard in conf.shards:
    if shard >= numShardsInNetwork:
      let msg =
        "validateShards invalid shard: " & $shard & " when numShardsInNetwork: " &
        $numShardsInNetwork # fmt doesn't work
      error "validateShards failed", error = msg
      return err(msg)

  return ok()

proc getNodeKey*(
    conf: WakuNodeConf, rng: ref HmacDrbgContext = crypto.newRng()
): Result[PrivateKey, string] =
  if conf.nodekey.isSome():
    return ok(conf.nodekey.get())

  warn "missing node key, generating new set"
  let key = crypto.PrivateKey.random(Secp256k1, rng[]).valueOr:
    error "Failed to generate key", error = error
    return err("Failed to generate key: " & $error)
  return ok(key)
