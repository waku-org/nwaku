import
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  std/[macros, net, options, sequtils, strutils],
  chronicles,
  results

import
  ./waku_conf, ./networks_config, ../common/logging, ../common/utils/parse_size_units

logScope:
  topics = "waku conf builder"

proc generateWithProc(builderType, argName, argType, targetType: NimNode): NimNode =
  builderType.expectKind nnkIdent
  argName.expectKind nnkIdent

  result = newStmtList()

  let procName = ident("with" & capitalizeAscii($argName))
  let builderIdent = ident("builder")
  let builderVar = newDotExpr(builderIdent, ident($argName))
  let resVar = ident($argName)

  if argType == targetType:
    result.add quote do:
      proc `procName`*(`builderIdent`: var `builderType`, `resVar`: `argType`) =
        `builderVar` = some(`argName`)

  else:
    result.add quote do:
      proc `procName`*(`builderIdent`: var `builderType`, `resVar`: `argType`) =
        `builderVar` = some(`argName`.`targetType`)

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
macro with(
    builderType: untyped, argName: untyped, argType: untyped, targetType: untyped
) =
  result = generateWithProc(builderType, argName, argType, targetType)

## A simple macro to set a property on the builder, and convert the property
## to the right (distinct) type.
## 
## For example:
## 
## ```
## with(RlnRelayConfBuilder, ethContractAddress, string, ContractAddress)
## ```
## 
## Generates
## 
## ```
## proc withRlnRelay*(builder: var RlnRelayConfBuilder, ethContractAddress: string) = 
##  builder.ethContractAddress = some(ethContractAddress.ContractAddress)
## ```
macro with(builderType: untyped, argName: untyped, argType: untyped) =
  result = generateWithProc(builderType, argName, argType, argType)

##############################
## RLN Relay Config Builder ##
##############################
type RlnRelayConfBuilder = ref object
  rlnRelay: Option[bool]
  ethContractAddress: Option[ContractAddress]
  chainId: Option[uint]
  credIndex: Option[uint]
  dynamic: Option[bool]
  bandwidthThreshold: Option[int]
  epochSizeSec: Option[uint64]
  userMessageLimit: Option[uint64]
  ethClientAddress: Option[EthRpcUrl]

proc init*(T: type RlnRelayConfBuilder): RlnRelayConfBuilder =
  RlnRelayConfBuilder()

with(RlnRelayConfbuilder, rlnRelay, bool)
with(RlnRelayConfBuilder, chainId, uint)
with(RlnRelayConfBuilder, credIndex, uint)
with(RlnRelayConfBuilder, dynamic, bool)
with(RlnRelayConfBuilder, bandwidthThreshold, int)
with(RlnRelayConfBuilder, epochSizeSec, uint64)
with(RlnRelayConfBuilder, userMessageLimit, uint64)
with(RlnRelayConfBuilder, ethContractAddress, string, ContractAddress)
with(RlnRelayConfBuilder, ethClientAddress, string, EthRpcUrl)

proc build*(builder: RlnRelayConfBuilder): Result[Option[RlnRelayConf], string] =
  if builder.rlnRelay.isNone or not builder.rlnRelay.get():
    info "RLN Relay is disabled"
    return ok(none(RlnRelayConf))

  let ethContractAddress =
    if builder.ethContractAddress.isSome:
      builder.ethContractAddress.get()
    else:
      return err("RLN Eth Contract Address was not specified")

  let chainId =
    if builder.chainId.isSome:
      builder.chainId.get()
    else:
      return err("RLN Relay Chain Id was not specified")

  let dynamic =
    if builder.dynamic.isSome:
      builder.dynamic.get()
    else:
      return err("RLN Relay Dynamic was not specified")

  let bandwidthThreshold =
    if builder.bandwidthThreshold.isSome:
      builder.bandwidthThreshold.get()
    else:
      return err("RLN Relay Bandwidth Threshold was not specified")

  let epochSizeSec =
    if builder.epochSizeSec.isSome:
      builder.epochSizeSec.get()
    else:
      return err("RLN Epoch Size was not specified")

  let userMessageLimit =
    if builder.userMessageLimit.isSome:
      builder.userMessageLimit.get()
    else:
      return err("RLN Relay User Message Limit was not specified")

  let ethClientAddress =
    if builder.ethClientAddress.isSome:
      builder.ethClientAddress.get()
    else:
      return err("RLN Relay Eth Client Address was not specified")

  return ok(
    some(
      RlnRelayConf(
        chainId: chainId,
        credIndex: credIndex,
        dynamic: dynamic,
        ethContractAddress: ethContractAddress,
        epochSizeSec: epochSizeSec,
        userMessageLimit: userMessageLimit,
        ethClientAddress: ethClientAddress,
      )
    )
  )

###########################
## Store Config Builder ##
###########################
type StoreServiceConfBuilder = ref object
  store: Option[bool]
  legacy: Option[bool]

proc init(T: type StoreServiceConfBuilder): StoreServiceConfBuilder =
  StoreServiceConfBuilder()

with(StoreServiceConfBuilder, store, bool)
with(StoreServiceConfBuilder, legacy, bool)

proc build(builder: StoreServiceConfBuilder): Result[Option[StoreServiceConf], string] =
  if builder.store.get(false):
    return ok(none(StoreServiceConf))

  return ok(some(StoreServiceConf(legacy: builder.legacy.get(true))))

###########################
## Discv5 Config Builder ##
###########################
type Discv5ConfBuilder = ref object
  discv5: Option[bool]
  bootstrapNodes: Option[seq[TextEnr]]
  udpPort: Option[Port]

proc init(T: type Discv5ConfBuilder): Discv5ConfBuilder =
  Discv5ConfBuilder()

with(Discv5ConfBuilder, discv5, bool)
with(Discv5ConfBuilder, udpPort, uint16, Port)

proc withBootstrapNodes(builder: var Discv5ConfBuilder, bootstrapNodes: seq[string]) =
  # TODO: validate ENRs?
  builder.bootstrapNodes = some(
    bootstrapNodes.map(
      proc(e: string): TextEnr =
        e.TextEnr
    )
  )

proc build(builder: Discv5ConfBuilder): Result[Option[Discv5Conf], string] =
  if not builder.discv5.get(false):
    return ok(none(Discv5Conf))

  # TODO: Do we need to ensure there are bootstrap nodes?
  # Not sure discv5 is of any use without bootstrap nodes
  # Confirmed: discv5 is useless without bootstrap node - config valid function?
  let bootstrapNodes = builder.bootstrapNodes.get(@[])

  let udpPort =
    if builder.udpPort.isSome:
      builder.udpPort.get()
    else:
      return err("Discv5 UDP Port was not specified")

  return ok(some(Discv5Conf(bootstrapNodes: bootstrapNodes, udpPort: udpPort)))

##############################
## WebSocket Config Builder ##
##############################
type WebSocketConfBuilder* = ref object
  webSocketSupport: Option[bool]
  webSocketPort: Option[Port]
  webSocketSecureSupport: Option[bool]
  webSocketSecureKeyPath: Option[string]
  webSocketSecureCertPath: Option[string]

proc init*(T: type WebSocketConfBuilder): WebSocketConfBuilder =
  WebSocketConfBuilder()

with(WebSocketConfBuilder, webSocketSupport, bool)
with(WebSocketConfBuilder, webSocketSecureSupport, bool)
with(WebSocketConfBuilder, webSocketPort, Port)
with(WebSocketConfBuilder, webSocketSecureKeyPath, string)
with(WebSocketConfBuilder, webSocketSecureCertPath, string)

proc build(builder: WebSocketConfBuilder): Result[Option[WebSocketConf], string] =
  if not builder.webSocketSupport.get(false):
    return ok(none(WebSocketConf))

  let webSocketPort =
    if builder.webSocketPort.isSome:
      builder.webSocketPort.get()
    else:
      warn "WebSocket Port is not specified, defaulting to 8000"
      8000.Port

  if not builder.webSocketSecureSupport.get(false):
    return ok(
      some(WebSocketConf(port: websocketPort, secureConf: none(WebSocketSecureConf)))
    )

  let webSocketSecureKeyPath = builder.webSocketSecureKeyPath.get("")
  if webSocketSecureKeyPath == "":
    return err("WebSocketSecure enabled but key path is not specified")

  let webSocketSecureCertPath = builder.webSocketSecureCertPath.get("")
  if webSocketSecureCertPath == "":
    return err("WebSocketSecure enabled but cert path is not specified")

  return ok(
    some(
      WebSocketConf(
        port: webSocketPort,
        secureConf: some(
          WebSocketSecureConf(
            keyPath: webSocketSecureKeyPath, certPath: webSocketSecureCertPath
          )
        ),
      )
    )
  )

## `WakuConfBuilder` is a convenient tool to accumulate
## Config parameters to build a `WakuConfig`.
## It provides some type conversion, as well as applying
## defaults in an agnostic manner (for any usage of Waku node)
type WakuConfBuilder* = ref object
  nodeKey: Option[PrivateKey]

  clusterId: Option[uint16]
  numShardsInNetwork: Option[uint32]
  shards: Option[seq[uint16]]

  relay: Option[bool]
  filter: Option[bool]
  lightPush: Option[bool]
  peerExchange: Option[bool]
  storeSync: Option[bool]
  relayPeerExchange: Option[bool]
  discv5Only: Option[bool]

  clusterConf: Option[ClusterConf]

  storeServiceConf: StoreServiceConfBuilder
  rlnRelayConf*: RlnRelayConfBuilder

  maxMessageSizeBytes: Option[int]

  discv5Conf*: Discv5ConfBuilder

  logLevel: Option[logging.LogLevel]
  logFormat: Option[logging.LogFormat]

  natStrategy: Option[NatStrategy]

  p2pTcpPort: Option[Port]
  p2pListenAddress: Option[IpAddress]
  portsShift: Option[uint16]
  dns4DomainName: Option[DomainName]
  extMultiAddrs: seq[string]
  extMultiAddrsOnly: Option[bool]

  webSocketConf*: WebSocketConfBuilder

  dnsAddrs: Option[bool]
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

proc init*(T: type WakuConfBuilder): WakuConfBuilder =
  WakuConfBuilder(
    storeServiceConf: StoreServiceConfBuilder.init(),
    rlnRelayConf: RlnRelayConfBuilder.init(),
    discv5Conf: Discv5ConfBuilder.init(),
    webSocketConf: WebSocketConfBuilder.init(),
  )

with(WakuConfBuilder, clusterConf, ClusterConf)
with(WakuConfBuilder, nodeKey, PrivateKey)
with(WakuConfBuilder, clusterId, uint16)
with(WakuConfBuilder, relay, bool)
with(WakuConfBuilder, filter, bool)
with(WakuConfBuilder, storeSync, bool)
with(WakuConfBuilder, relayPeerExchange, bool)
with(WakuConfBuilder, maxMessageSizeBytes, int)
with(WakuConfBuilder, dnsAddrs, bool)
with(WakuConfbuilder, peerPersistence, bool)
with(WakuConfbuilder, maxConnections, int)
with(WakuConfbuilder, shards, seq[uint16])
with(WakuConfbuilder, dnsAddrsNameServers, seq[IpAddress])
with(WakuConfbuilder, p2pTcpPort, uint16, Port)
with(WakuConfbuilder, dns4DomainName, string, DomainName)
with(WakuConfbuilder, agentString, string)
with(WakuConfBuilder, colocationLimit, int)
with(WakuConfBuilder, rateLimits, seq[string])
with(WakuConfBuilder, maxRelayPeers, int)
with(WakuConfBuilder, relayServiceRatio, string)

proc withExtMultiAddr*(builder: var WakuConfBuilder, extMultiAddr: string) =
  builder.extMultiAddrs.add(extMultiAddr)

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

proc applyPresetConf(builder: var WakuConfBuilder) =
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
    var rlnRelayConf = builder.rlnRelayConf

    if rlnRelayConf.rlnRelay.isNone:
      rlnRelayConf.withRlnRelay(true)
    else:
      warn "RLN Relay was manually provided alongside a cluster conf",
        used = rlnRelayConf.rlnRelay, discarded = clusterConf.rlnRelay

    if rlnRelayConf.ethContractAddress.isNone:
      rlnRelayConf.withEthContractAddress(clusterConf.rlnRelayEthContractAddress)
    else:
      warn "RLN Relay ETH Contract Address was manually provided alongside a cluster conf",
        used = rlnRelayConf.ethContractAddress.get().string,
        discarded = clusterConf.rlnRelayEthContractAddress.string

    if rlnRelayConf.chainId.isNone:
      rlnRelayConf.withChainId(clusterConf.rlnRelayChainId)
    else:
      warn "RLN Relay Chain Id was manually provided alongside a cluster conf",
        used = rlnRelayConf.chainId, discarded = clusterConf.rlnRelayChainId

    if rlnRelayConf.dynamic.isNone:
      rlnRelayConf.withDynamic(clusterConf.rlnRelayDynamic)
    else:
      warn "RLN Relay Dynamic was manually provided alongside a cluster conf",
        used = rlnRelayConf.dynamic, discarded = clusterConf.rlnRelayDynamic

    if rlnRelayConf.bandwidthThreshold.isNone:
      rlnRelayConf.withBandwidthThreshold(clusterConf.rlnRelayBandwidthThreshold)
    else:
      warn "RLN Relay Bandwidth Threshold was manually provided alongside a cluster conf",
        used = rlnRelayConf.bandwidthThreshold,
        discarded = clusterConf.rlnRelayBandwidthThreshold

    if rlnRelayConf.epochSizeSec.isNone:
      rlnRelayConf.withEpochSizeSec(clusterConf.rlnEpochSizeSec)
    else:
      warn "RLN Epoch Size in Seconds was manually provided alongside a cluster conf",
        used = rlnRelayConf.epochSizeSec, discarded = clusterConf.rlnEpochSizeSec

    if rlnRelayConf.userMessageLimit.isNone:
      rlnRelayConf.withUserMessageLimit(clusterConf.rlnRelayUserMessageLimit)
    else:
      warn "RLN Relay Dynamic was manually provided alongside a cluster conf",
        used = rlnRelayConf.userMessageLimit,
        discarded = clusterConf.rlnRelayUserMessageLimit
  # End Apply relay parameters

  if builder.maxMessageSizeBytes.isNone:
    builder.maxMessageSizeBytes =
      some(int(parseCorrectMsgSize(clusterConf.maxMessageSize)))
  else:
    warn "Max Message Size was manually provided alongside a cluster conf",
      used = builder.maxMessageSizeBytes, discarded = clusterConf.maxMessageSize

  if builder.numShardsInNetwork.isNone:
    builder.numShardsInNetwork = some(clusterConf.numShardsInNetwork)
  else:
    warn "Num Shards In Network was manually provided alongside a cluster conf",
      used = builder.numShardsInNetwork, discarded = clusterConf.numShardsInNetwork

  if clusterConf.discv5Discovery:
    var discv5ConfBuilder = builder.discv5Conf

    if discv5ConfBuilder.discv5.isNone:
      discv5ConfBuilder.withDiscv5(clusterConf.discv5Discovery)

    if discv5ConfBuilder.bootstrapNodes.isNone and
        clusterConf.discv5BootstrapNodes.len > 0:
      discv5ConfBuilder.withBootstrapNodes(clusterConf.discv5BootstrapNodes)

proc build*(
    builder: var WakuConfBuilder, rng: ref HmacDrbgContext = crypto.newRng()
): Result[WakuConf, string] =
  ## Return a WakuConf that contains all mandatory parameters
  ## Applies some sane defaults that are applicable across any usage
  ## of libwaku. It aims to be agnostic so it does not apply a 
  ## default when it is opinionated.

  let relay =
    if builder.relay.isSome:
      builder.relay.get()
    else:
      warn "whether to mount relay is not specified, defaulting to not mounting"
      false

  let filter =
    if builder.filter.isSome:
      builder.filter.get()
    else:
      warn "whether to mount filter is not specified, defaulting to not mounting"
      false

  let lightPush =
    if builder.lightPush.isSome:
      builder.lightPush.get()
    else:
      warn "whether to mount lightPush is not specified, defaulting to not mounting"
      false

  let peerExchange =
    if builder.peerExchange.isSome:
      builder.peerExchange.get()
    else:
      warn "whether to mount peerExchange is not specified, defaulting to not mounting"
      false

  let storeSync =
    if builder.storeSync.isSome:
      builder.storeSync.get()
    else:
      warn "whether to mount storeSync is not specified, defaulting to not mounting"
      false

  let relayPeerExchange = builder.relayPeerExchange.get(false)

  applyPresetConf(builder)

  let nodeKey = ?nodeKey(builder, rng)

  let clusterId =
    if builder.clusterId.isSome:
      builder.clusterId.get()
    else:
      return err("Cluster Id was not specified")

  let numShardsInNetwork =
    if builder.numShardsInNetwork.isSome:
      builder.numShardsInNetwork.get()
    else:
      warn "Number of shards in network not specified, defaulting to one shard"
      1

  let shards =
    if builder.shards.isSome:
      builder.shards.get()
    else:
      warn "shards not specified, defaulting to all shards in network"
      # TODO: conversion should not be needed
      let upperShard: uint16 = uint16(numShardsInNetwork - 1)
      toSeq(0.uint16 .. upperShard)

  let discv5Conf = builder.discv5Conf.build().valueOr:
    return err("Discv5 Conf building failed: " & $error)

  let storeServiceConf = builder.storeServiceConf.build().valueOr:
    return err("Store Conf building failed: " & $error)

  let rlnRelayConf = builder.rlnRelayConf.build().valueOr:
    return err("RLN Relay Conf building failed: " & $error)

  let webSocketConf = builder.webSocketConf.build().valueOr:
    return err("WebSocket Conf building failed: " & $error)

  let maxMessageSizeBytes =
    if builder.maxMessageSizeBytes.isSome:
      builder.maxMessageSizeBytes.get()
    else:
      return err("Max Message Size was not specified")

  let logLevel =
    if builder.logLevel.isSome:
      builder.logLevel.get()
    else:
      warn "Log Level not specified, defaulting to INFO"
      logging.LogLevel.INFO

  let logFormat =
    if builder.logFormat.isSome:
      builder.logFormat.get()
    else:
      warn "Log Format not specified, defaulting to TEXT"
      logging.LogFormat.TEXT

  let natStrategy =
    if builder.natStrategy.isSome:
      builder.natStrategy.get()
    else:
      warn "Nat Strategy is not specified, defaulting to none"
      "none".NatStrategy

  let p2pTcpPort =
    if builder.p2pTcpPort.isSome:
      builder.p2pTcpPort.get()
    else:
      warn "P2P Listening TCP Port is not specified, listening on 60000"
      6000.Port

  let p2pListenAddress =
    if builder.p2pListenAddress.isSome:
      builder.p2pListenAddress.get()
    else:
      warn "P2P listening address not specified, listening on 0.0.0.0"
      (static parseIpAddress("0.0.0.0"))

  let portsShift =
    if builder.portsShift.isSome:
      builder.portsShift.get()
    else:
      warn "Ports Shift is not specified, defaulting to 0"
      0.uint16

  let dns4DomainName =
    if builder.dns4DomainName.isSome:
      let d = builder.dns4DomainName.get()
      if d.string != "":
        some(d)
      else:
        none(DomainName)
    else:
      none(DomainName)

  var extMultiAddrs: seq[MultiAddress] = @[]
  for s in builder.extMultiAddrs:
    let m = MultiAddress.init(s).valueOr:
      return err("Invalid multiaddress provided: " & s)
    extMultiAddrs.add(m)

  let extMultiAddrsOnly =
    if builder.extMultiAddrsOnly.isSome:
      builder.extMultiAddrsOnly.get()
    else:
      warn "Whether to only announce external multiaddresses is not specified, defaulting to false"
      false

  let dnsAddrs =
    if builder.dnsAddrs.isSome:
      builder.dnsAddrs.get()
    else:
      warn "Whether to resolve DNS multiaddresses was not specified, defaulting to false."
      false

  let dnsAddrsNameServers =
    if builder.dnsAddrsNameServers.isSome:
      builder.dnsAddrsNameServers.get()
    else:
      warn "DNS name servers IPs not provided, defaulting to Cloudflare's."
      @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")]

  let peerPersistence =
    if builder.peerPersistence.isSome:
      builder.peerPersistence.get()
    else:
      warn "Peer persistence not specified, defaulting to false"
      false

  let maxConnections =
    if builder.maxConnections.isSome:
      builder.maxConnections.get()
    else:
      return err "Max Connections was not specified"

  let relayServiceRatio =
    if builder.relayServiceRatio.isSome:
      builder.relayServiceRatio.get()
    else:
      return err "Relay Service Ratio was not specified"

  # TODO: Do the git version thing here
  let agentString = builder.agentString.get("nwaku")

  # TODO: use `DefaultColocationLimit`. the user of this value should
  # probably be defining a config object
  let colocationLimit = builder.colocationLimit.get(5)
  let rateLimits = builder.rateLimits.get(newSeq[string](0))

  # TODO: is there a strategy for experimental features? delete vs promote
  let relayShardedPeerManagement = builder.relayShardedPeerManagement.get(false)

  return ok(
    WakuConf(
      nodeKey: nodeKey,
      clusterId: clusterId,
      numShardsInNetwork: numShardsInNetwork,
      contentTopics: contentTopics,
      shards: shards,
      protectedShards: protectedShards,
      relay: relay,
      filter: filter,
      lightPush: lightPush,
      peerExchange: peerExchange,
      rendezvous: rendezvous,
      storeServiceConf: storeServiceConf,
      relayPeerExchange: relayPeerExchange,
      discv5Conf: discv5Conf,
      rlnRelayConf: rlnRelayConf,
      maxMessageSizeBytes: maxMessageSizeBytes,
      logLevel: logLevel,
      logFormat: logFormat,
      natStrategy: natStrategy,
      p2pTcpPort: p2pTcpPort,
      p2pListenAddress: p2pListenAddress,
      portsShift: portsShift,
      dns4DomainName: dns4DomainName,
      extMultiAddrs: extMultiAddrs,
      extMultiAddrsOnly: extMultiAddrsOnly,
      webSocketConf: webSocketConf,
      dnsAddrs: dnsAddrs,
      dnsAddrsNameServers: dnsAddrsNameServers,
      peerPersistence: peerPersistence,
      peerStoreCapacity: builder.peerStoreCapacity,
      maxConnections: maxConnections,
      agentString: agentString,
      colocationLimit: colocationLimit,
      maxRelayPeers: builder.maxRelayPeers,
      relayServiceRatio: relayServiceRatio,
      rateLimits: rateLimits,
    )
  )
