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
    factory/external_config,
    factory/internal_config,
    factory/builder,
  ],
  ./common

# Waku node

proc defaultTestWakuNodeConf*(): WakuNodeConf =
  ## set cluster-id == 0 to not use TWN as that needs a background blockchain (e.g. anvil)
  ## running because RLN is mounted if TWN (cluster-id == 1) is configured.
  WakuNodeConf(
    cmd: noCommand,
    tcpPort: Port(60000),
    websocketPort: Port(8000),
    listenAddress: parseIpAddress("0.0.0.0"),
    restAddress: parseIpAddress("127.0.0.1"),
    metricsServerAddress: parseIpAddress("127.0.0.1"),
    dnsAddrsNameServers: @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
    nat: "any",
    maxConnections: 50,
    relayServiceRatio: "60:40",
    maxMessageSize: "1024 KiB",
    clusterId: DefaultClusterId,
    shards: @[DefaultShardId],
    relay: true,
    rendezvous: true,
    storeMessageDbUrl: "sqlite://store.sqlite3",
  )

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

  var conf = defaultTestWakuNodeConf()

  conf.clusterId = clusterId
  conf.shards = shards

  if dns4DomainName.isSome() and extIp.isNone():
    # If there's an error resolving the IP, an exception is thrown and test fails
    let dns = (waitFor dnsResolve(dns4DomainName.get(), conf)).valueOr:
      raise newException(Defect, error)

    resolvedExtIp = some(parseIpAddress(dns))

  let netConf = NetConfig.init(
    bindIp = bindIp,
    clusterId = conf.clusterId,
    bindPort = bindPort,
    extIp = resolvedExtIp,
    extPort = extPort,
    extMultiAddrs = extMultiAddrs,
    wsBindPort = wsBindPort,
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    wakuFlags = wakuFlags,
    dns4DomainName = dns4DomainName,
    discv5UdpPort = discv5UdpPort,
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
