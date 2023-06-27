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
  ../../../waku/v2/waku_node,
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/waku_enr,
  ../../../waku/v2/waku_discv5,
  ./common


# Waku node

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
                      peerStoreCapacity = none(int)): WakuNode =
  let netConfigRes = NetConfig.init(
    bindIp = bindIp,
    bindPort = bindPort,
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = extMultiAddrs,
    wsBindPort = wsBindPort,
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    wakuFlags = wakuFlags,
    dns4DomainName = dns4DomainName,
    discv5UdpPort = discv5UdpPort,
  )
  if netConfigRes.isErr():
    raise newException(Defect, "Invalid network configuration: " & $netConfigRes.error)

  var builder = WakuNodeBuilder.init()
  builder.withRng(rng())
  builder.withNodeKey(nodeKey)
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
