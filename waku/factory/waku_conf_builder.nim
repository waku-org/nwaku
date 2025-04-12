import
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  std/[macros, net, options, sequtils, strutils],
  chronicles,
  results

import
  ./waku_conf,
  ./networks_config,
  ../common/logging,
  ../common/utils/parse_size_units,
  ../waku_enr/capabilities

logScope:
  topics = "waku conf builder"

proc generateWithProc(builderType, argName, argType, fromType: NimNode): NimNode =
  builderType.expectKind nnkIdent
  argName.expectKind nnkIdent

  result = newStmtList()

  let procName = ident("with" & capitalizeAscii($argName))
  let builderIdent = ident("builder")
  let builderVar = newDotExpr(builderIdent, ident($argName))
  let resVar = ident($argName)

  if argType == fromType:
    result.add quote do:
      proc `procName`*(`builderIdent`: var `builderType`, `resVar`: `argType`) =
        `builderVar` = some(`argName`)

  else:
    result.add quote do:
      proc `procName`*(`builderIdent`: var `builderType`, `resVar`: `fromType`) =
        `builderVar` = some(`argName`.`argType`)

## A simple macro to set a property on the builder.
## For example:
## 
## ```
## with(RlnRelayConfbuilder, rlnRelay, bool)
## ```
## 
## Generates
## 
## ```
## proc withRlnRelay*(builder: var RlnRelayConfBuilder, rlnRelay: bool) = 
##  builder.rlnRelay = some(rlnRelay)
## ```
macro with(builderType: untyped, argName: untyped, argType: untyped) =
  result = generateWithProc(builderType, argName, argType, argType)

## A simple macro to set a property on the builder, and convert the property
## to the right type.
## 
## For example:
## 
## ```
## with(WakuConfBuilder, p2pPort, Port, uint16)
## ```
## 
## Generates
## 
## ```
## proc withp2pPort*(builder: var WakuConfBuilStoreServder, p2pPort: uint16) = 
##  builder.p2pPort = some(p2pPort.Port)
## ```
macro with(
    builderType: untyped, argName: untyped, argType: untyped, fromType: untyped
) =
  result = generateWithProc(builderType, argName, argType, fromType)

##############################
## RLN Relay Config Builder ##
##############################
type RlnRelayConfBuilder = object
  enabled: Option[bool]

  chainId: Option[uint]
  ethClientAddress: Option[string]
  ethContractAddress: Option[string]
  credIndex: Option[uint]
  credPassword: Option[string]
  credPath: Option[string]
  dynamic: Option[bool]
  epochSizeSec: Option[uint64]
  userMessageLimit: Option[uint64]
  treePath: Option[string]

proc init*(T: type RlnRelayConfBuilder): RlnRelayConfBuilder =
  RlnRelayConfBuilder()

with(RlnRelayConfbuilder, enabled, bool)

with(RlnRelayConfBuilder, chainId, uint)
with(RlnRelayConfBuilder, credIndex, uint)
with(RlnRelayConfBuilder, credPassword, string)
with(RlnRelayConfBuilder, credPath, string)
with(RlnRelayConfBuilder, dynamic, bool)
with(RlnRelayConfBuilder, ethClientAddress, string)
with(RlnRelayConfBuilder, ethContractAddress, string)
with(RlnRelayConfBuilder, epochSizeSec, uint64)
with(RlnRelayConfBuilder, userMessageLimit, uint64)
with(RlnRelayConfBuilder, treePath, string)

proc build*(b: RlnRelayConfBuilder): Result[Option[RlnRelayConf], string] =
  if not b.enabled.get(false):
    return ok(none(RlnRelayConf))

  if b.chainId.isNone():
    return err("RLN Relay Chain Id is not specified")

  let creds =
    if b.credPath.isSome() and b.credPassword.isSome():
      some(RlnRelayCreds(path: b.credPath.get(), password: b.credPassword.get()))
    elif b.credPath.isSome() and b.credPassword.isNone():
      return err("RLN Relay Credential Password is not specified but path is")
    elif b.credPath.isNone() and b.credPassword.isSome():
      return err("RLN Relay Credential Path is not specified but password is")
    else:
      none(RlnRelayCreds)

  if b.dynamic.isNone():
    return err("rlnRelay.dynamic is not specified")
  if b.ethClientAddress.get("") == "":
    return err("rlnRelay.ethClientAddress is not specified")
  if b.ethContractAddress.get("") == "":
    return err("rlnRelay.ethContractAddress is not specified")
  if b.epochSizeSec.isNone():
    return err("rlnRelay.epochSizeSec is not specified")
  if b.userMessageLimit.isNone():
    return err("rlnRelay.userMessageLimit is not specified")
  if b.treePath.isNone():
    return err("rlnRelay.treePath is not specified")

  return ok(
    some(
      RlnRelayConf(
        chainId: b.chainId.get(),
        credIndex: b.credIndex,
        creds: creds,
        dynamic: b.dynamic.get(),
        ethClientAddress: b.ethClientAddress.get(),
        ethContractAddress: b.ethContractAddress.get(),
        epochSizeSec: b.epochSizeSec.get(),
        userMessageLimit: b.userMessageLimit.get(),
        treePath: b.treePath.get(),
      )
    )
  )

###################################
## Filter Service Config Builder ##
###################################
type FilterServiceConfBuilder = object
  enabled: Option[bool]
  maxPeersToServe: Option[uint32]
  subscriptionTimeout: Option[uint16]
  maxCriteria: Option[uint32]

proc init(T: type FilterServiceConfBuilder): FilterServiceConfBuilder =
  FilterServiceConfBuilder()

with(FilterServiceConfBuilder, enabled, bool)
with(FilterServiceConfBuilder, maxPeersToServe, uint32)
with(FilterServiceConfBuilder, subscriptionTimeout, uint16)
with(FilterServiceConfBuilder, maxCriteria, uint32)

proc build(b: FilterServiceConfBuilder): Result[Option[FilterServiceConf], string] =
  if not b.enabled.get(false):
    return ok(none(FilterServiceConf))

  return ok(
    some(
      FilterServiceConf(
        maxPeersToServe: b.maxPeersToServe.get(500),
        subscriptionTimeout: b.subscriptionTimeout.get(300),
        maxCriteria: b.maxCriteria.get(1000),
      )
    )
  )

##################################
## Store Sync Config Builder ##
##################################
type StoreSyncConfBuilder = object
  enabled: Option[bool]

  rangeSec: Option[uint32]
  intervalSec: Option[uint32]
  relayJitterSec: Option[uint32]

proc init(T: type StoreSyncConfBuilder): StoreSyncConfBuilder =
  StoreSyncConfBuilder()

with(StoreSyncConfBuilder, enabled, bool)
with(StoreSyncConfBuilder, rangeSec, uint32)
with(StoreSyncConfBuilder, intervalSec, uint32)
with(StoreSyncConfBuilder, relayJitterSec, uint32)

proc build(b: StoreSyncConfBuilder): Result[Option[StoreSyncConf], string] =
  if not b.enabled.get(false):
    return ok(none(StoreSyncConf))

  if b.rangeSec.isNone():
    return err "store.rangeSec is not specified"
  if b.intervalSec.isNone():
    return err "store.intervalSec is not specified"
  if b.relayJitterSec.isNone():
    return err "store.relayJitterSec is not specified"

  return ok(
    some(
      StoreSyncConf(
        rangeSec: b.rangeSec.get(),
        intervalSec: b.intervalSec.get(),
        relayJitterSec: b.relayJitterSec.get(),
      )
    )
  )

##################################
## Store Service Config Builder ##
##################################
type StoreServiceConfBuilder = object
  enabled: Option[bool]

  dbMigration: Option[bool]
  dbURl: Option[string]
  dbVacuum: Option[bool]
  legacy: Option[bool]
  maxNumDbConnections: Option[int]
  retentionPolicy: Option[string]
  resume: Option[bool]
  storeSyncConf*: StoreSyncConfBuilder

proc init(T: type StoreServiceConfBuilder): StoreServiceConfBuilder =
  StoreServiceConfBuilder(storeSyncConf: StoreSyncConfBuilder.init())

with(StoreServiceConfBuilder, enabled, bool)
with(StoreServiceConfBuilder, dbMigration, bool)
with(StoreServiceConfBuilder, dbURl, string)
with(StoreServiceConfBuilder, dbVacuum, bool)
with(StoreServiceConfBuilder, legacy, bool)
with(StoreServiceConfBuilder, maxNumDbConnections, int)
with(StoreServiceConfBuilder, retentionPolicy, string)
with(StoreServiceConfBuilder, resume, bool)

proc build(b: StoreServiceConfBuilder): Result[Option[StoreServiceConf], string] =
  if not b.enabled.get(false):
    return ok(none(StoreServiceConf))

  if b.dbMigration.isNone():
    return err "store.dbMigration is not specified"
  if b.dbUrl.get("") == "":
    return err "store.dbUrl is not specified"
  if b.dbVacuum.isNone():
    return err "store.dbVacuum is not specified"
  if b.legacy.isNone():
    return err "store.legacy is not specified"
  if b.maxNumDbConnections.isNone():
    return err "store.maxNumDbConnections is not specified"
  if b.retentionPolicy.get("") == "":
    return err "store.retentionPolicy is not specified"
  if b.resume.isNone():
    return err "store.resume is not specified"

  let storeSyncConf = b.storeSyncConf.build().valueOr:
    return err("Store Sync Conf failed to build")

  return ok(
    some(
      StoreServiceConf(
        dbMigration: b.dbMigration.get(),
        dbURl: b.dbUrl.get(),
        dbVacuum: b.dbVacuum.get(),
        legacy: b.legacy.get(),
        maxNumDbConnections: b.maxNumDbConnections.get(),
        retentionPolicy: b.retentionPolicy.get(),
        resume: b.resume.get(),
        storeSyncConf: storeSyncConf,
      )
    )
  )

################################
## REST Server Config Builder ##
################################
type RestServerConfBuilder = object
  enabled: Option[bool]

  allowOrigin: seq[string]
  listenAddress: Option[IpAddress]
  port: Option[Port]
  admin: Option[bool]
  relayCacheCapacity: Option[uint32]

proc init(T: type RestServerConfBuilder): RestServerConfBuilder =
  RestServerConfBuilder()

proc withAllowOrigin*(builder: var RestServerConfBuilder, allowOrigin: seq[string]) =
  builder.allowOrigin = concat(builder.allowOrigin, allowOrigin)

with(RestServerConfBuilder, enabled, bool)
with(RestServerConfBuilder, listenAddress, IpAddress)
with(RestServerConfBuilder, port, Port, uint16)
with(RestServerConfBuilder, admin, bool)
with(RestServerConfBuilder, relayCacheCapacity, uint32)

proc build(b: RestServerConfBuilder): Result[Option[RestServerConf], string] =
  if not b.enabled.get(false):
    return ok(none(RestServerConf))

  if b.listenAddress.isNone():
    return err("restServer.listenAddress is not specified")
  if b.port.isNone():
    return err("restServer.port is not specified")
  if b.relayCacheCapacity.isNone():
    return err("restServer.relayCacheCapacity is not specified")

  return ok(
    some(
      RestServerConf(
        allowOrigin: b.allowOrigin,
        listenAddress: b.listenAddress.get(),
        port: b.port.get(),
        admin: b.admin.get(false),
        relayCacheCapacity: b.relayCacheCapacity.get(),
      )
    )
  )

##################################
## DNS Discovery Config Builder ##
##################################
type DnsDiscoveryConfBuilder = object
  enabled: Option[bool]
  enrTreeUrl: Option[string]
  nameServers: seq[IpAddress]

proc init(T: type DnsDiscoveryConfBuilder): DnsDiscoveryConfBuilder =
  DnsDiscoveryConfBuilder()

with(DnsDiscoveryConfBuilder, enabled, bool)
with(DnsDiscoveryConfBuilder, enrTreeUrl, string)

proc withNameServers*(b: var DnsDiscoveryConfBuilder, nameServers: seq[IpAddress]) =
  b.nameServers = concat(b.nameServers, nameServers)

proc build(b: DnsDiscoveryConfBuilder): Result[Option[DnsDiscoveryConf], string] =
  if not b.enabled.get(false):
    return ok(none(DnsDiscoveryConf))

  if b.nameServers.len == 0:
    return err("dnsDiscovery.nameServers is not specified")
  if b.enrTreeUrl.isNone():
    return err("dnsDiscovery.enrTreeUrl is not specified")

  return ok(
    some(DnsDiscoveryConf(nameServers: b.nameServers, enrTreeUrl: b.enrTreeUrl.get()))
  )

#################################
## AutoSharding Config Builder ##
#################################
type AutoShardingConfBuilder = object
  enabled: Option[bool]
  numShardsInNetwork*: Option[uint16]
  contentTopics*: seq[string]

proc init(T: type AutoShardingConfBuilder): AutoShardingConfBuilder =
  AutoShardingConfBuilder()

with(AutoShardingConfBuilder, enabled, bool)

proc build(b: AutoShardingConfBuilder): Result[Option[AutoShardingConf], string] =
  if not b.enabled.get(false):
    return ok(none(AutoShardingConf))

  if b.numShardsInNetwork.isNone:
    return err("autoSharding.numShardsInNetwork is not specified")

  return ok(
    some(
      AutoShardingConf(
        numShardsInNetwork: b.numShardsInNetwork.get(), contentTopics: b.contentTopics
      )
    )
  )

###########################
## Discv5 Config Builder ##
###########################
type Discv5ConfBuilder = object
  enabled: Option[bool]

  bootstrapNodes: seq[string]
  bitsPerHop: Option[int]
  bucketIpLimit: Option[uint]
  discv5Only: Option[bool]
  enrAutoUpdate: Option[bool]
  tableIpLimit: Option[uint]
  udpPort: Option[Port]

proc init(T: type Discv5ConfBuilder): Discv5ConfBuilder =
  Discv5ConfBuilder()

with(Discv5ConfBuilder, enabled, bool)
with(Discv5ConfBuilder, bitsPerHop, int)
with(Discv5ConfBuilder, bucketIpLimit, uint)
with(Discv5ConfBuilder, discv5Only, bool)
with(Discv5ConfBuilder, enrAutoUpdate, bool)
with(Discv5ConfBuilder, tableIpLimit, uint)
with(Discv5ConfBuilder, udpPort, Port, uint16)
with(Discv5ConfBuilder, udpPort, Port)

proc withBootstrapNodes*(builder: var Discv5ConfBuilder, bootstrapNodes: seq[string]) =
  # TODO: validate ENRs?
  builder.bootstrapNodes = concat(builder.bootstrapNodes, bootstrapNodes)

proc build(b: Discv5ConfBuilder): Result[Option[Discv5Conf], string] =
  if not b.enabled.get(false):
    return ok(none(Discv5Conf))

  # Discv5 is useless without bootstrap nodes
  if b.bootstrapNodes.len == 0:
    return err("dicv5.bootstrapNodes is not specified")

  return ok(
    some(
      Discv5Conf(
        bootstrapNodes: b.bootstrapNodes,
        bitsPerHop: b.bitsPerHop.get(1),
        bucketIpLimit: b.bucketIpLimit.get(2),
        discv5Only: b.discv5Only.get(false),
        enrAutoUpdate: b.enrAutoUpdate.get(true),
        tableIpLimit: b.tableIpLimit.get(10),
        udpPort: b.udpPort.get(9000.Port),
      )
    )
  )

##############################
## WebSocket Config Builder ##
##############################
type WebSocketConfBuilder* = object
  enabled: Option[bool]
  webSocketPort: Option[Port]
  secureEnabled: Option[bool]
  keyPath: Option[string]
  certPath: Option[string]

proc init*(T: type WebSocketConfBuilder): WebSocketConfBuilder =
  WebSocketConfBuilder()

with(WebSocketConfBuilder, enabled, bool)
with(WebSocketConfBuilder, secureEnabled, bool)
with(WebSocketConfBuilder, webSocketPort, Port)
with(WebSocketConfBuilder, webSocketPort, Port, uint16)
with(WebSocketConfBuilder, keyPath, string)
with(WebSocketConfBuilder, certPath, string)

proc build(b: WebSocketConfBuilder): Result[Option[WebSocketConf], string] =
  if not b.enabled.get(false):
    return ok(none(WebSocketConf))

  if b.webSocketPort.isNone():
    return err("websocket.port is not specified")

  if not b.secureEnabled.get(false):
    return ok(
      some(
        WebSocketConf(
          port: b.websocketPort.get(), secureConf: none(WebSocketSecureConf)
        )
      )
    )

  if b.keyPath.get("") == "":
    return err("WebSocketSecure enabled but key path is not specified")
  if b.certPath.get("") == "":
    return err("WebSocketSecure enabled but cert path is not specified")

  return ok(
    some(
      WebSocketConf(
        port: b.webSocketPort.get(),
        secureConf: some(
          WebSocketSecureConf(keyPath: b.keyPath.get(), certPath: b.certPath.get())
        ),
      )
    )
  )

###################################
## Metrics Server Config Builder ##
###################################
type MetricsServerConfBuilder = object
  enabled: Option[bool]

  httpAddress: Option[IpAddress]
  httpPort: Option[Port]
  logging: Option[bool]

proc init(T: type MetricsServerConfBuilder): MetricsServerConfBuilder =
  MetricsServerConfBuilder()

with(MetricsServerConfBuilder, enabled, bool)
with(MetricsServerConfBuilder, httpAddress, IpAddress)
with(MetricsServerConfBuilder, httpPort, Port, uint16)
with(MetricsServerConfBuilder, logging, bool)

proc build(b: MetricsServerConfBuilder): Result[Option[MetricsServerConf], string] =
  if not b.enabled.get(false):
    return ok(none(MetricsServerConf))

  return ok(
    some(
      MetricsServerConf(
        httpAddress: b.httpAddress.get(parseIpAddress("127.0.0.1")),
        httpPort: b.httpPort.get(8008.Port),
        logging: b.logging.get(false),
      )
    )
  )

type MaxMessageSizeKind = enum
  mmskNone
  mmskStr
  mmskInt

type MaxMessageSize = object
  case kind: MaxMessageSizeKind
  of mmskNone:
    discard
  of mmskStr:
    str: string
  of mmskInt:
    bytes: uint64

## `WakuConfBuilder` is a convenient tool to accumulate
## Config parameters to build a `WakuConfig`.
## It provides some type conversion, as well as applying
## defaults in an agnostic manner (for any usage of Waku node)
#
# TODO: Sub protocol builder (eg `StoreServiceConfBuilder`
# is be better defined in the protocol module (eg store)
# and apply good defaults from this protocol PoV and make the
# decision when the dev must specify a value vs when a default
# is fine to have.
#
# TODO: Add default to most values so that when a developer uses
# the builder, it works out-of-the-box
type WakuConfBuilder* = object
  nodeKey: Option[PrivateKey]

  clusterId: Option[uint16]

  shards: Option[seq[uint16]]
  protectedShards: Option[seq[ProtectedShard]]
  contentTopics: Option[seq[string]]

  # Conf builders
  autoShardingConf*: AutoShardingConfBuilder
  dnsDiscoveryConf*: DnsDiscoveryConfBuilder
  discv5Conf*: Discv5ConfBuilder
  filterServiceConf*: FilterServiceConfBuilder
  metricsServerConf*: MetricsServerConfBuilder
  restServerConf*: RestServerConfBuilder
  rlnRelayConf*: RlnRelayConfBuilder
  storeServiceConf*: StoreServiceConfBuilder
  webSocketConf*: WebSocketConfBuilder
  # End conf builders
  relay: Option[bool]
  lightPush: Option[bool]
  peerExchange: Option[bool]
  storeSync: Option[bool]
  relayPeerExchange: Option[bool]
  # TODO: move within a relayConf
  rendezvous: Option[bool]
  discv5Only: Option[bool]

  clusterConf: Option[ClusterConf]

  staticNodes: seq[string]

  remoteStoreNode: Option[string]
  remoteLightPushNode: Option[string]
  remoteFilterNode: Option[string]
  remotePeerExchangeNode: Option[string]

  maxMessageSize: MaxMessageSize

  logLevel: Option[logging.LogLevel]
  logFormat: Option[logging.LogFormat]

  natStrategy: Option[string]

  p2pTcpPort: Option[Port]
  p2pListenAddress: Option[IpAddress]
  portsShift: Option[uint16]
  dns4DomainName: Option[string]
  extMultiAddrs: seq[string]
  extMultiAddrsOnly: Option[bool]

  dnsAddrs: Option[bool]
  # TODO: Option of an array is probably silly, instead, offer concat utility with `with`
  dnsAddrsNameServers: Option[seq[IpAddress]]
  peerPersistence: Option[bool]
  peerStoreCapacity: Option[int]
  maxConnections: Option[int]
  colocationLimit: Option[int]

  agentString: Option[string]

  rateLimits: Option[seq[string]]

  maxRelayPeers: Option[int]
  relayShardedPeerManagement: Option[bool]
  relayServiceRatio: Option[string]
  circuitRelayClient: Option[bool]
  keepAlive: Option[bool]
  p2pReliability: Option[bool]

proc init*(T: type WakuConfBuilder): WakuConfBuilder =
  WakuConfBuilder(
    autoShardingConf: AutoShardingConfBuilder.init(),
    dnsDiscoveryConf: DnsDiscoveryConfBuilder.init(),
    discv5Conf: Discv5ConfBuilder.init(),
    filterServiceConf: FilterServiceConfBuilder.init(),
    metricsServerConf: MetricsServerConfBuilder.init(),
    restServerConf: RestServerConfBuilder.init(),
    rlnRelayConf: RlnRelayConfBuilder.init(),
    storeServiceConf: StoreServiceConfBuilder.init(),
    webSocketConf: WebSocketConfBuilder.init(),
  )

with(WakuConfBuilder, clusterConf, ClusterConf)
with(WakuConfBuilder, nodeKey, PrivateKey)
with(WakuConfBuilder, clusterId, uint16)
with(WakuConfBuilder, shards, seq[uint16])
with(WakuConfBuilder, protectedShards, seq[ProtectedShard])
with(WakuConfBuilder, relay, bool)
with(WakuConfBuilder, lightPush, bool)
with(WakuConfBuilder, storeSync, bool)
with(WakuConfBuilder, peerExchange, bool)
with(WakuConfBuilder, relayPeerExchange, bool)
with(WakuConfBuilder, rendezvous, bool)
with(WakuConfBuilder, remoteStoreNode, string)
with(WakuConfBuilder, remoteLightPushNode, string)
with(WakuConfBuilder, remoteFilterNode, string)
with(WakuConfBuilder, remotePeerExchangeNode, string)
with(WakuConfBuilder, dnsAddrs, bool)
with(WakuConfBuilder, peerPersistence, bool)
with(WakuConfBuilder, peerStoreCapacity, int)
with(WakuConfBuilder, maxConnections, int)
with(WakuConfBuilder, dnsAddrsNameServers, seq[IpAddress])
with(WakuConfBuilder, logLevel, logging.LogLevel)
with(WakuConfBuilder, logFormat, logging.LogFormat)
with(WakuConfBuilder, p2pTcpPort, Port)
with(WakuConfBuilder, p2pTcpPort, Port, uint16)
with(WakuConfBuilder, portsShift, uint16)
with(WakuConfBuilder, p2pListenAddress, IpAddress)
with(WakuConfBuilder, extMultiAddrsOnly, bool)
with(WakuConfBuilder, dns4DomainName, string)
with(WakuConfBuilder, natStrategy, string)
with(WakuConfBuilder, agentString, string)
with(WakuConfBuilder, colocationLimit, int)
with(WakuConfBuilder, rateLimits, seq[string])
with(WakuConfBuilder, maxRelayPeers, int)
with(WakuConfBuilder, relayServiceRatio, string)
with(WakuConfBuilder, circuitRelayClient, bool)
with(WakuConfBuilder, relayShardedPeerManagement, bool)
with(WakuConfBuilder, keepAlive, bool)
with(WakuConfBuilder, p2pReliability, bool)

proc withExtMultiAddrs*(builder: var WakuConfBuilder, extMultiAddrs: seq[string]) =
  builder.extMultiAddrs = concat(builder.extMultiAddrs, extMultiAddrs)

proc withMaxMessageSize*(builder: var WakuConfBuilder, maxMessageSizeBytes: uint64) =
  builder.maxMessageSize = MaxMessageSize(kind: mmskInt, bytes: maxMessageSizeBytes)

proc withMaxMessageSize*(builder: var WakuConfBuilder, maxMessageSize: string) =
  builder.maxMessageSize = MaxMessageSize(kind: mmskStr, str: maxMessageSize)

proc withStaticNodes*(builder: var WakuConfBuilder, staticNodes: seq[string]) =
  builder.staticNodes = concat(builder.staticNodes, staticNodes)

proc nodeKey(
    builder: WakuConfBuilder, rng: ref HmacDrbgContext
): Result[PrivateKey, string] =
  if builder.nodeKey.isSome():
    return ok(builder.nodeKey.get())
  else:
    warn "missing node key, generating new set"
    let nodeKey = crypto.PrivateKey.random(Secp256k1, rng[]).valueOr:
      error "Failed to generate key", error = error
      return err("Failed to generate key: " & $error)
    return ok(nodeKey)

proc applyClusterConf(builder: var WakuConfBuilder) =
  # Apply cluster conf - values passed manually override cluster conf
  # Should be applied **first**, before individual values are pulled
  if builder.clusterConf.isNone:
    return
  var clusterConf = builder.clusterConf.get()

  if builder.clusterId.isNone:
    builder.clusterId = some(clusterConf.clusterId)
  else:
    warn "Cluster id was manually provided alongside a cluster conf",
      used = builder.clusterId, discarded = clusterConf.clusterId

  # Apply relay parameters
  if builder.relay.get(false) and clusterConf.rlnRelay:
    if builder.rlnRelayConf.enabled.isNone:
      builder.rlnRelayConf.withEnabled(true)
    else:
      warn "RLN Relay was manually provided alongside a cluster conf",
        used = builder.rlnRelayConf.enabled, discarded = clusterConf.rlnRelay

    if builder.rlnRelayConf.ethContractAddress.isNone:
      builder.rlnRelayConf.withEthContractAddress(
        clusterConf.rlnRelayEthContractAddress
      )
    else:
      warn "RLN Relay ETH Contract Address was manually provided alongside a cluster conf",
        used = builder.rlnRelayConf.ethContractAddress.get().string,
        discarded = clusterConf.rlnRelayEthContractAddress.string

    if builder.rlnRelayConf.chainId.isNone:
      builder.rlnRelayConf.withChainId(clusterConf.rlnRelayChainId)
    else:
      warn "RLN Relay Chain Id was manually provided alongside a cluster conf",
        used = builder.rlnRelayConf.chainId, discarded = clusterConf.rlnRelayChainId

    if builder.rlnRelayConf.dynamic.isNone:
      builder.rlnRelayConf.withDynamic(clusterConf.rlnRelayDynamic)
    else:
      warn "RLN Relay Dynamic was manually provided alongside a cluster conf",
        used = builder.rlnRelayConf.dynamic, discarded = clusterConf.rlnRelayDynamic

    if builder.rlnRelayConf.epochSizeSec.isNone:
      builder.rlnRelayConf.withEpochSizeSec(clusterConf.rlnEpochSizeSec)
    else:
      warn "RLN Epoch Size in Seconds was manually provided alongside a cluster conf",
        used = builder.rlnRelayConf.epochSizeSec,
        discarded = clusterConf.rlnEpochSizeSec

    if builder.rlnRelayConf.userMessageLimit.isNone:
      builder.rlnRelayConf.withUserMessageLimit(clusterConf.rlnRelayUserMessageLimit)
    else:
      warn "RLN Relay Dynamic was manually provided alongside a cluster conf",
        used = builder.rlnRelayConf.userMessageLimit,
        discarded = clusterConf.rlnRelayUserMessageLimit
  # End Apply relay parameters

  case builder.maxMessageSize.kind
  of mmskNone:
    builder.withMaxMessageSize(parseCorrectMsgSize(clusterConf.maxMessageSize))
  of mmskStr, mmskInt:
    warn "Max Message Size was manually provided alongside a cluster conf",
      used = $builder.maxMessageSize, discarded = clusterConf.maxMessageSize

  if builder.autoShardingConf.numShardsInNetwork.isNone:
    builder.autoShardingConf.numShardsInNetwork = clusterConf.numShardsInNetwork
  else:
    warn "Num Shards In Network was manually provided alongside a cluster conf",
      used = builder.autoShardingConf.numShardsInNetwork,
      discarded = clusterConf.numShardsInNetwork

  if clusterConf.discv5Discovery:
    if builder.discv5Conf.enabled.isNone:
      builder.discv5Conf.withEnabled(clusterConf.discv5Discovery)

    if builder.discv5Conf.bootstrapNodes.len == 0 and
        clusterConf.discv5BootstrapNodes.len > 0:
      builder.discv5Conf.withBootstrapNodes(clusterConf.discv5BootstrapNodes)

proc build*(
    builder: var WakuConfBuilder, rng: ref HmacDrbgContext = crypto.newRng()
): Result[WakuConf, string] =
  ## Return a WakuConf that contains all mandatory parameters
  ## Applies some sane defaults that are applicable across any usage
  ## of libwaku. It aims to be agnostic so it does not apply a 
  ## default when it is opinionated.

  let relay =
    if builder.relay.isSome():
      builder.relay.get()
    else:
      warn "whether to mount relay is not specified, defaulting to not mounting"
      false

  let lightPush =
    if builder.lightPush.isSome():
      builder.lightPush.get()
    else:
      warn "whether to mount lightPush is not specified, defaulting to not mounting"
      false

  let peerExchange =
    if builder.peerExchange.isSome():
      builder.peerExchange.get()
    else:
      warn "whether to mount peerExchange is not specified, defaulting to not mounting"
      false

  let storeSync =
    if builder.storeSync.isSome():
      builder.storeSync.get()
    else:
      warn "whether to mount storeSync is not specified, defaulting to not mounting"
      false

  let rendezvous =
    if builder.rendezvous.isSome():
      builder.rendezvous.get()
    else:
      warn "whether to mount rendezvous is not specified, defaulting to not mounting"
      false

  let relayPeerExchange = builder.relayPeerExchange.get(false)

  applyClusterConf(builder)

  let nodeKey = ?nodeKey(builder, rng)

  if builder.clusterId.isNone():
    return err("Cluster Id was not specified")

  let shards =
    if builder.shards.isSome():
      builder.shards.get()
    elif builder.autoShardingConf.numShardsInNetwork.isSome():
      info "shards not specified and auto-sharding is enabled via numShardsInNetwork, subscribing to all shards in network"
      let upperShard: uint16 = builder.autoShardingConf.numShardsInNetwork.get() - 1
      toSeq(0.uint16 .. upperShard)
    else:
      return err("")

  let protectedShards = builder.protectedShards.get(@[])

  let maxMessageSizeBytes =
    case builder.maxMessageSize.kind
    of mmskInt:
      builder.maxMessageSize.bytes
    of mmskStr:
      ?parseMsgSize(builder.maxMessageSize.str)
    else:
      warn "Max Message Size not specified, defaulting to 150KiB"
      parseCorrectMsgSize("150KiB")

  let contentTopics = builder.contentTopics.get(@[])

  # Build sub-configs
  let autoShardingConf = builder.autoShardingConf.build().valueOr:
    return err("AutoSharding Conf building failed: " & $error)

  let discv5Conf = builder.discv5Conf.build().valueOr:
    return err("Discv5 Conf building failed: " & $error)

  let dnsDiscoveryConf = builder.dnsDiscoveryConf.build().valueOr:
    return err("DNS Discovery Conf building failed: " & $error)

  let filterServiceConf = builder.filterServiceConf.build().valueOr:
    return err("Filter Service Conf building failed: " & $error)

  let metricsServerConf = builder.metricsServerConf.build().valueOr:
    return err("Metrics Server Conf building failed: " & $error)

  let restServerConf = builder.restServerConf.build().valueOr:
    return err("REST Server Conf building failed: " & $error)

  let rlnRelayConf = builder.rlnRelayConf.build().valueOr:
    return err("RLN Relay Conf building failed: " & $error)

  let storeServiceConf = builder.storeServiceConf.build().valueOr:
    return err("Store Conf building failed: " & $error)

  let webSocketConf = builder.webSocketConf.build().valueOr:
    return err("WebSocket Conf building failed: " & $error)
  # End - Build sub-configs

  let logLevel =
    if builder.logLevel.isSome():
      builder.logLevel.get()
    else:
      warn "Log Level not specified, defaulting to INFO"
      logging.LogLevel.INFO

  let logFormat =
    if builder.logFormat.isSome():
      builder.logFormat.get()
    else:
      warn "Log Format not specified, defaulting to TEXT"
      logging.LogFormat.TEXT

  let natStrategy =
    if builder.natStrategy.isSome():
      builder.natStrategy.get()
    else:
      warn "Nat Strategy is not specified, defaulting to none"
      "none"

  let p2pTcpPort =
    if builder.p2pTcpPort.isSome():
      builder.p2pTcpPort.get()
    else:
      warn "P2P Listening TCP Port is not specified, listening on 60000"
      60000.Port

  let p2pListenAddress =
    if builder.p2pListenAddress.isSome():
      builder.p2pListenAddress.get()
    else:
      warn "P2P listening address not specified, listening on 0.0.0.0"
      (static parseIpAddress("0.0.0.0"))

  let portsShift =
    if builder.portsShift.isSome():
      builder.portsShift.get()
    else:
      warn "Ports Shift is not specified, defaulting to 0"
      0.uint16

  let dns4DomainName =
    if builder.dns4DomainName.isSome():
      let d = builder.dns4DomainName.get()
      if d.string != "":
        some(d)
      else:
        none(string)
    else:
      none(string)

  var extMultiAddrs: seq[MultiAddress] = @[]
  for s in builder.extMultiAddrs:
    let m = MultiAddress.init(s).valueOr:
      return err("Invalid multiaddress provided: " & s)
    extMultiAddrs.add(m)

  let extMultiAddrsOnly =
    if builder.extMultiAddrsOnly.isSome():
      builder.extMultiAddrsOnly.get()
    else:
      warn "Whether to only announce external multiaddresses is not specified, defaulting to false"
      false

  let dnsAddrs =
    if builder.dnsAddrs.isSome():
      builder.dnsAddrs.get()
    else:
      warn "Whether to resolve DNS multiaddresses was not specified, defaulting to false."
      false

  let dnsAddrsNameServers =
    if builder.dnsAddrsNameServers.isSome():
      builder.dnsAddrsNameServers.get()
    else:
      warn "DNS name servers IPs not provided, defaulting to Cloudflare's."
      @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")]

  let peerPersistence =
    if builder.peerPersistence.isSome():
      builder.peerPersistence.get()
    else:
      warn "Peer persistence not specified, defaulting to false"
      false

  let maxConnections =
    if builder.maxConnections.isSome():
      builder.maxConnections.get()
    else:
      warn "Max Connections was not specified, defaulting to 300"
      300

  # TODO: Do the git version thing here
  let agentString = builder.agentString.get("nwaku")

  # TODO: use `DefaultColocationLimit`. the user of this value should
  # probably be defining a config object
  let colocationLimit = builder.colocationLimit.get(5)
  let rateLimits = builder.rateLimits.get(newSeq[string](0))

  # TODO: is there a strategy for experimental features? delete vs promote
  let relayShardedPeerManagement = builder.relayShardedPeerManagement.get(false)

  let wakuFlags = CapabilitiesBitfield.init(
    lightpush = lightPush,
    filter = filterServiceConf.isSome,
    store = storeServiceConf.isSome,
    relay = relay,
    sync = storeServiceConf.isSome() and storeServiceConf.get().storeSyncConf.isSome,
  )

  let wakuConf = WakuConf(
    # confs
    storeServiceConf: storeServiceConf,
    filterServiceConf: filterServiceConf,
    discv5Conf: discv5Conf,
    rlnRelayConf: rlnRelayConf,
    metricsServerConf: metricsServerConf,
    restServerConf: restServerConf,
    dnsDiscoveryConf: dnsDiscoveryConf,
    # end confs
    nodeKey: nodeKey,
    clusterId: builder.clusterId.get(),
    numShardsInNetwork: numShardsInNetwork,
    contentTopics: contentTopics,
    shards: shards,
    protectedShards: protectedShards,
    relay: relay,
    lightPush: lightPush,
    peerExchange: peerExchange,
    rendezvous: rendezvous,
    remoteStoreNode: builder.remoteStoreNode,
    remoteLightPushNode: builder.remoteLightPushNode,
    remoteFilterNode: builder.remoteFilterNode,
    remotePeerExchangeNode: builder.remotePeerExchangeNode,
    relayPeerExchange: relayPeerExchange,
    maxMessageSizeBytes: maxMessageSizeBytes,
    logLevel: logLevel,
    logFormat: logFormat,
    # TODO: Separate builders
    networkConf: NetworkConfig(
      natStrategy: natStrategy,
      p2pTcpPort: p2pTcpPort,
      dns4DomainName: dns4DomainName,
      p2pListenAddress: p2pListenAddress,
      extMultiAddrs: extMultiAddrs,
      extMultiAddrsOnly: extMultiAddrsOnly,
    ),
    portsShift: portsShift,
    webSocketConf: webSocketConf,
    dnsAddrs: dnsAddrs,
    dnsAddrsNameServers: dnsAddrsNameServers,
    peerPersistence: peerPersistence,
    peerStoreCapacity: builder.peerStoreCapacity,
    maxConnections: maxConnections,
    agentString: agentString,
    colocationLimit: colocationLimit,
    maxRelayPeers: builder.maxRelayPeers,
    relayServiceRatio: builder.relayServiceRatio.get("60:40"),
    rateLimits: rateLimits,
    circuitRelayClient: builder.circuitRelayClient.get(false),
    keepAlive: builder.keepAlive.get(true),
    staticNodes: builder.staticNodes,
    relayShardedPeerManagement: relayShardedPeerManagement,
    p2pReliability: builder.p2pReliability.get(false),
    wakuFlags: wakuFlags,
  )

  ?wakuConf.validate()

  return ok(wakuConf)
