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
  libp2p/nameresolving/nameresolver,
  libp2p/transports/wstransport
import
  ../waku_enr,
  ../waku_discv5,
  ./config,
  ./peer_manager,
  ./waku_node,
  ./waku_switch


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

    # Peer manager config
    maxRelayPeers: Option[int]

    # Libp2p switch
    switchMaxConnections: Option[int]
    switchNameResolver: Option[NameResolver]
    switchAgentString: Option[string]
    switchSslSecureKey: Option[string]
    switchSslSecureCert: Option[string]
    switchSendSignedPeerRecord: Option[bool]

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
          dns4DomainName = none(string)): WakuNodeBuilderResult {.
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
  )
  builder.withNetworkConfiguration(netConfig)
  ok()


## Peer storage and peer manager

proc withPeerStorage*(builder: var WakuNodeBuilder, peerStorage: PeerStorage, capacity = none(int)) =
  if not peerStorage.isNil():
    builder.peerStorage = some(peerStorage)

  builder.peerStorageCapacity = capacity

proc withPeerManagerConfig*(builder: var WakuNodeBuilder,
                            maxRelayPeers = none(int)) =
  builder.maxRelayPeers = maxRelayPeers



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

  if builder.record.isNone():
    return err("node record is required")

  var switch: Switch
  try:
    switch = newWakuSwitch(
      privKey = builder.nodekey,
      address = builder.netConfig.get().hostAddress,
      wsAddress = builder.netConfig.get().wsHostAddress,
      transportFlags = {ServerFlags.ReuseAddr},
      rng = rng,
      maxConnections = builder.switchMaxConnections.get(builders.MaxConnections),
      wssEnabled = builder.netConfig.get().wssEnabled,
      secureKeyPath = builder.switchSslSecureKey.get(""),
      secureCertPath = builder.switchSslSecureCert.get(""),
      nameResolver = builder.switchNameResolver.get(nil),
      sendSignedPeerRecord = builder.switchSendSignedPeerRecord.get(false),
      agentString = builder.switchAgentString,
      peerStoreCapacity = builder.peerStorageCapacity,
      services = @[Service(getAutonatService(rng))],
    )
  except CatchableError:
    return err("failed to create switch: " & getCurrentExceptionMsg())

  let peerManager = PeerManager.new(
    switch = switch,
    storage = builder.peerStorage.get(nil),
    maxRelayPeers = builder.maxRelayPeers,
  )

  var node: WakuNode
  try:
    node = WakuNode.new(
      netConfig = builder.netConfig.get(),
      enr = builder.record.get(),
      switch = switch,
      peerManager = peerManager,
      rng = rng,
    )
  except Exception:
    return err("failed to build WakuNode instance: " & getCurrentExceptionMsg())

  ok(node)
