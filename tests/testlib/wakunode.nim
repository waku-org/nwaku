import
  std/options,
  results,
  stew/shims/net,
  chronos,
  libp2p/switch,
  libp2p/builders,
  libp2p/nameresolving/nameresolver,
  libp2p/crypto/crypto as libp2p_keys,
  eth/keys as eth_keys
import
  waku/[
    waku_node,
    waku_core/topics,
    node/peer_manager,
    waku_enr,
    discovery/waku_discv5,
    factory/internal_config,
    factory/waku_conf,
    factory/waku_conf_builder,
    factory/builder,
  ],
  ./common

# Waku node

# TODO: migrate to usage of a test cluster conf
proc defaultTestWakuConf*(): WakuConf =
  var builder = WakuConfBuilder.init()
  builder.withP2pTcpPort(Port(60000))
  builder.webSocketConf.withEnabled(true)
  builder.webSocketConf.withWebSocketPort(Port(8000))
  builder.withP2pListenAddress(parseIpAddress("0.0.0.0"))
  builder.restServerConf.withListenAddress(parseIpAddress("127.0.0.1"))
  builder.withDnsAddrsNameServers(
    @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")]
  )
  builder.withNatStrategy("any")
  builder.withMaxConnections(50)
  builder.withRelayServiceRatio("60:40")
  builder.withMaxMessageSize("1024 KiB")
  builder.withClusterId(DefaultClusterId)
  builder.withShards(@[DefaultShardId])
  builder.withRelay(true)
  builder.withRendezvous(true)
  return builder.build().value

proc newTestWakuNode*(
    nodeKey: crypto.PrivateKey,
    bindIp: IpAddress,
    bindPort: Port,
    extIp = none(IpAddress),
    extPort = none(Port),
    extMultiAddrs = newSeq[MultiAddress](),
    peerStorage: PeerStorage = nil,
    maxConnections = builders.MaxConnections,
    wsBindPort: Port = (Port) 8000,
    wsEnabled: bool = false,
    wssEnabled: bool = false,
    secureKey: string = "",
    secureCert: string = "",
    wakuFlags = none(CapabilitiesBitfield),
    nameResolver: NameResolver = nil,
    sendSignedPeerRecord = false,
    dns4DomainName = none(string),
    discv5UdpPort = none(Port),
    agentString = none(string),
    peerStoreCapacity = none(int),
    clusterId = DefaultClusterId,
    shards = @[DefaultShardId],
): WakuNode =
  var resolvedExtIp = extIp

  # Update extPort to default value if it's missing and there's an extIp or a DNS domain
  let extPort =
    if (extIp.isSome() or dns4DomainName.isSome()) and extPort.isNone():
      some(Port(60000))
    else:
      extPort

  var conf = defaultTestWakuConf()

  conf.clusterId = clusterId
  conf.shards = shards

  if dns4DomainName.isSome() and extIp.isNone():
    # If there's an error resolving the IP, an exception is thrown and test fails
    let dns = (waitFor dnsResolve(dns4DomainName.get(), conf.dnsAddrsNameServers)).valueOr:
      raise newException(Defect, error)

    resolvedExtIp = some(parseIpAddress(dns))

  let netConf = NetConfig.init(
    clusterId = conf.clusterId,
    bindIp = bindIp,
    bindPort = bindPort,
    extIp = resolvedExtIp,
    extPort = extPort,
    extMultiAddrs = extMultiAddrs,
    wsBindPort = some(wsBindPort),
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    dns4DomainName = dns4DomainName,
    discv5UdpPort = discv5UdpPort,
    wakuFlags = wakuFlags,
  ).valueOr:
    raise newException(Defect, "Invalid network configuration: " & error)

  var enrBuilder = EnrBuilder.init(nodeKey)

  enrBuilder.withWakuRelaySharding(
    RelayShards(clusterId: conf.clusterId, shardIds: conf.shards)
  ).isOkOr:
    raise newException(Defect, "Invalid record: " & $error)

  enrBuilder.withIpAddressAndPorts(
    ipAddr = netConf.enrIp, tcpPort = netConf.enrPort, udpPort = netConf.discv5UdpPort
  )

  enrBuilder.withMultiaddrs(netConf.enrMultiaddrs)

  if netConf.wakuFlags.isSome():
    enrBuilder.withWakuCapabilities(netConf.wakuFlags.get())

  let record = enrBuilder.build().valueOr:
    raise newException(Defect, "Invalid record: " & $error)

  var builder = WakuNodeBuilder.init()
  builder.withRng(rng())
  builder.withNodeKey(nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConf)
  builder.withPeerStorage(peerStorage, capacity = peerStoreCapacity)
  builder.withSwitchConfiguration(
    maxConnections = some(maxConnections),
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord,
    secureKey =
      if secureKey != "":
        some(secureKey)
      else:
        none(string),
    secureCert =
      if secureCert != "":
        some(secureCert)
      else:
        none(string),
    agentString = agentString,
  )

  return builder.build().get()
