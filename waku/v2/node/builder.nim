when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  stew/shims/net,
  chronicles,
  libp2p/crypto/crypto,
  libp2p/builders,
  libp2p/nameresolving/nameresolver
import
  ../waku_enr,
  ../waku_discv5,
  ./config,
  ./peer_manager,
  ./waku_node


type
  WakuNodeBuilder* = object
    # General
    nodeRng: Option[ref crypto.HmacDrbgContext]
    nodeKey: Option[crypto.PrivateKey]
    netConfig: Option[NetConfig]
    record: Option[enr.Record]

    # Peer storage and peer manager
    peerStorage: Option[PeerStorage]
    peerStorageCapacity: Option[int]
    peerManager: Option[PeerManager]

    # Libp2p switch
    switchMaxConnections: Option[int]
    switchNameResolver: Option[NameResolver]
    switchAgentString: Option[string]
    switchSslSecureKey: Option[string]
    switchSslSecureCert: Option[string]
    switchSendSignedPeerRecord: Option[bool]

    # Waku discv5
    wakuDiscv5: Option[WakuDiscoveryV5]

  WakuNodeBuilderResult* = Result[void, string]


## Init

proc init*(T: type WakuNodeBuilder): WakuNodeBuilder =
  WakuNodeBuilder()


## General

proc withRng*(builder: var WakuNodeBuilder, rng: ref crypto.HmacDrbgContext) =
  builder.nodeRng = some(rng)

proc withNodeKey*(builder: var WakuNodeBuilder, nodeKey: crypto.PrivateKey) =
  builder.nodeKey = some(nodeKey)

proc withRecord*(builder: var WakuNodeBuilder, record: enr.Record) =
  builder.record = some(record)

proc withNetworkConfiguration*(builder: var WakuNodeBuilder, config: NetConfig) =
  builder.netConfig = some(config)

proc withNetworkConfigurationDetails*(builder: var WakuNodeBuilder,
          bindIp: ValidIpAddress,
          bindPort: Port,
          extIp = none(ValidIpAddress),
          extPort = none(Port),
          extMultiAddrs = newSeq[MultiAddress](),
          wsBindPort: Port = Port(8000),
          wsEnabled: bool = false,
          wssEnabled: bool = false,
          wakuFlags = none(CapabilitiesBitfield),
          dns4DomainName = none(string),
          discv5UdpPort = none(Port)): WakuNodeBuilderResult {.
  deprecated: "use 'builder.withNetworkConfiguration()' instead".} =
  let netConfig = ? NetConfig.init(
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
  builder.withNetworkConfiguration(netConfig)
  ok()


## Peer storage and peer manager

proc withPeerStorage*(builder: var WakuNodeBuilder, peerStorage: PeerStorage, capacity = none(int)) =
  if not peerStorage.isNil():
    builder.peerStorage = some(peerStorage)

  builder.peerStorageCapacity = capacity

proc withPeerManager*(builder: var WakuNodeBuilder, peerManager: PeerManager) =
  builder.peerManager = some(peerManager)


## Waku switch

proc withSwitchConfiguration*(builder: var WakuNodeBuilder,
                              maxConnections = none(int),
                              nameResolver: NameResolver = nil,
                              sendSignedPeerRecord = false,
                              secureKey = none(string),
                              secureCert = none(string),
                              agentString = none(string)) =
  builder.switchMaxConnections = maxConnections
  builder.switchSendSignedPeerRecord = some(sendSignedPeerRecord)
  builder.switchSslSecureKey = secureKey
  builder.switchSslSecureCert = secureCert
  builder.switchAgentString = agentString

  if not nameResolver.isNil():
    builder.switchNameResolver = some(nameResolver)


## Waku discv5

proc withWakuDiscv5*(builder: var WakuNodeBuilder, instance: WakuDiscoveryV5) =
  if not instance.isNil():
    builder.wakuDiscv5 = some(instance)


## Build

proc build*(builder: WakuNodeBuilder): Result[WakuNode, string] =
  var rng: ref crypto.HmacDrbgContext
  if builder.nodeRng.isNone():
    rng = crypto.newRng()
  else:
    rng = builder.nodeRng.get()

  if builder.nodeKey.isNone():
    return err("node key is required")

  if builder.netConfig.isNone():
    return err("network configuration is required")

  var node: WakuNode
  try:
    node = WakuNode.new(
      rng = rng,
      nodeKey = builder.nodeKey.get(),
      netConfig = builder.netConfig.get(),
      enr = builder.record,
      peerStorage = builder.peerStorage.get(nil),
      peerStoreCapacity = builder.peerStorageCapacity,
      maxConnections = builder.switchMaxConnections.get(builders.MaxConnections),
      nameResolver = builder.switchNameResolver.get(nil),
      agentString = builder.switchAgentString,
      secureKey = builder.switchSslSecureKey.get(""),
      secureCert = builder.switchSslSecureCert.get(""),
      sendSignedPeerRecord = builder.switchSendSignedPeerRecord.get(false),
      wakuDiscv5 = builder.wakuDiscv5,
    )
  except Exception:
    return err("failed to build WakuNode instance: " & getCurrentExceptionMsg())

  ok(node)
