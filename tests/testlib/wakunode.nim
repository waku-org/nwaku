import
  std/options,
  stew/results,
  stew/shims/net,
  chronos,
  libp2p/switch,
  libp2p/builders,
  libp2p/nameresolving/nameresolver,
  libp2p/crypto/crypto as libp2p_keys,
  eth/keys as eth_keys
import
  ../../../waku/waku_node,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_enr,
  ../../../waku/waku_discv5,
  ../../apps/wakunode2/external_config,
  ../../apps/wakunode2/internal_config,
  ./common


# Waku node

proc defaultTestWakuNodeConf*(): WakuNodeConf =
  WakuNodeConf(
    cmd: noCommand,
    tcpPort: Port(60000),
    websocketPort: Port(8000),
    listenAddress: ValidIpAddress.init("0.0.0.0"),
    rpcAddress: ValidIpAddress.init("127.0.0.1"),
    restAddress: ValidIpAddress.init("127.0.0.1"),
    metricsServerAddress: ValidIpAddress.init("127.0.0.1"),
    dnsAddrsNameServers: @[ValidIpAddress.init("1.1.1.1"), ValidIpAddress.init("1.0.0.1")],
    nat: "any",
    maxConnections: 50,
    topics: @["/waku/2/default-waku/proto"],
    relay: true
  )

proc newTestWakuNode*(nodeKey: crypto.PrivateKey,
                      bindIp: ValidIpAddress,
                      bindPort: Port,
                      extIp = none(ValidIpAddress),
                      extPort = none(Port),
                      extMultiAddrs = newSeq[MultiAddress](),
                      peerStorage: PeerStorage = nil,
                      maxConnections = builders.MaxConnections,
                      wsBindPort: Port = (Port)8000,
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
                      clusterId: uint32 = 0.uint32,
                      peerStoreCapacity = none(int)): WakuNode =

  var resolvedExtIp = extIp

  # Update extPort to default value if it's missing and there's an extIp or a DNS domain
  let extPort = if (extIp.isSome() or dns4DomainName.isSome()) and
                extPort.isNone():
                some(Port(60000))
              else:
                extPort

  if dns4DomainName.isSome() and extIp.isNone():
    let conf = defaultTestWakuNodeConf()
    # If there's an error resolving the IP, an exception is thrown and test fails
    let dnsRes = waitFor dnsResolve(dns4DomainName.get(), conf)
    if dnsRes.isErr():
      raise newException(Defect, $dnsRes.error)
    else:
      resolvedExtIp = some(ValidIpAddress.init(dnsRes.get()))

  let netConfigRes = NetConfig.init(
    bindIp = bindIp,
    clusterId = clusterId,
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
  )
  let netConf =
    if netConfigRes.isErr():
      raise newException(Defect, "Invalid network configuration: " & $netConfigRes.error)
    else:
      netConfigRes.get()

  var enrBuilder = EnrBuilder.init(nodeKey)

  enrBuilder.withIpAddressAndPorts(
      ipAddr = netConf.enrIp,
      tcpPort = netConf.enrPort,
      udpPort = netConf.discv5UdpPort,
  )
  if netConf.wakuFlags.isSome():
    enrBuilder.withWakuCapabilities(netConf.wakuFlags.get())
  enrBuilder.withMultiaddrs(netConf.enrMultiaddrs)

  let recordRes = enrBuilder.build()
  let record =
    if recordRes.isErr():
      raise newException(Defect, "Invalid record: " & $recordRes.error)
    else:
      recordRes.get()

  var builder = WakuNodeBuilder.init()
  builder.withRng(rng())
  builder.withNodeKey(nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfigRes.get())
  builder.withPeerStorage(peerStorage, capacity = peerStoreCapacity)
  builder.withSwitchConfiguration(
    maxConnections = some(maxConnections),
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord,
    secureKey = if secureKey != "": some(secureKey) else: none(string),
    secureCert = if secureCert != "": some(secureCert) else: none(string),
    agentString = agentString,

  )

  return builder.build().get()
