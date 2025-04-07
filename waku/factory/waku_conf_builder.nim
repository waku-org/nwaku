import
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  std/[net, options, sequtils],
  chronicles,
  results

import
  ./waku_conf, ./networks_config, ../common/logging, ../common/utils/parse_size_units

logScope:
  topics = "waku conf builder"

##############################
## RLN Relay Config Builder ##
##############################
type RlnRelayConfBuilder = ref object
  rlnRelay: Option[bool]
  ethContractAddress: Option[ContractAddress]
  chainId: Option[uint]
  dynamic: Option[bool]
  bandwidthThreshold: Option[int]
  epochSizeSec: Option[uint64]
  userMessageLimit: Option[uint64]
  ethClientAddress: Option[EthRpcUrl]

proc init*(T: type RlnRelayConfBuilder): RlnRelayConfBuilder =
  RlnRelayConfBuilder()

proc withRlnRelay*(builder: var RlnRelayConfBuilder, rlnRelay: bool) =
  builder.rlnRelay = some(rlnRelay)

proc withEthContractAddress*(
    builder: var RlnRelayConfBuilder, ethContractAddress: string
) =
  builder.ethContractAddress = some(ethContractAddress.ContractAddress)

proc withChainId*(builder: var RlnRelayConfBuilder, chainId: uint) =
  builder.chainId = some(chainId)

proc withDynamic*(builder: var RlnRelayConfBuilder, dynamic: bool) =
  builder.dynamic = some(dynamic)

proc withBandwidthThreshold*(
    builder: var RlnRelayConfBuilder, bandwidthThreshold: int
) =
  builder.bandwidthThreshold = some(bandwidthThreshold)

proc withEpochSizeSec*(builder: var RlnRelayConfBuilder, epochSizeSec: uint64) =
  builder.epochSizeSec = some(epochSizeSec)

proc withUserMessageLimit*(builder: var RlnRelayConfBuilder, userMessageLimit: uint64) =
  builder.userMessageLimit = some(userMessageLimit)

proc withEthClientAddress*(builder: var RlnRelayConfBuilder, ethClientAddress: string) =
  builder.ethClientAddress = some(ethClientAddress.EthRpcUrl)

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
        dynamic: dynamic,
        ethContractAddress: ethContractAddress,
        epochSizeSec: epochSizeSec,
        userMessageLimit: userMessageLimit,
        ethClientAddress: ethClientAddress,
      )
    )
  )

###########################
## Discv5 Config Builder ##
###########################
type Discv5ConfBuilder = ref object
  discv5*: Option[bool]
  bootstrapNodes*: Option[seq[TextEnr]]
  udpPort*: Option[Port]

proc init(T: type Discv5ConfBuilder): Discv5ConfBuilder =
  Discv5ConfBuilder()

proc withDiscv5(builder: var Discv5ConfBuilder, discv5: bool) =
  builder.discv5 = some(discv5)

proc withBootstrapNodes(builder: var Discv5ConfBuilder, bootstrapNodes: seq[string]) =
  # TODO: validate ENRs?
  builder.bootstrapNodes = some(
    bootstrapNodes.map(
      proc(e: string): TextEnr =
        e.TextEnr
    )
  )

proc withUdpPort*(builder: var Discv5ConfBuilder, udpPort: uint16) =
  builder.udpPort = some (udpPort.Port)

proc build(builder: Discv5ConfBuilder): Result[Option[Discv5Conf], string] =
  if builder.discv5.isNone or not builder.discv5.get():
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

#########################
## Waku Config Builder ##
#########################
type WakuConfBuilder* = ref object
  nodeKey*: Option[PrivateKey]

  clusterId: Option[uint16]
  numShardsInNetwork: Option[uint32]
  shards: Option[seq[uint16]]

  relay: Option[bool]
  store: Option[bool]
  filter: Option[bool]
  lightPush: Option[bool]
  peerExchange: Option[bool]

  clusterConf: Option[ClusterConf]

  rlnRelayConf*: RlnRelayConfBuilder

  maxMessageSizeBytes: Option[int]

  discv5Conf*: Discv5ConfBuilder

  logLevel: Option[logging.LogLevel]
  logFormat: Option[logging.LogFormat]

  natStrategy: Option[NatStrategy]

  tcpPort: Option[Port]
  portsShift: Option[uint16]
  dns4DomainName: Option[DomainName]
  extMultiAddrs: seq[string]

proc init*(T: type WakuConfBuilder): WakuConfBuilder =
  WakuConfBuilder(
    rlnRelayConf: RlnRelayConfBuilder.init(), discv5Conf: Discv5ConfBuilder.init()
  )

proc withClusterConf*(builder: var WakuConfBuilder, clusterConf: ClusterConf) =
  builder.clusterConf = some(clusterConf)

proc withNodeKey*(builder: var WakuConfBuilder, nodeKey: PrivateKey) =
  builder.nodeKey = some(nodeKey)

proc withClusterId*(builder: var WakuConfBuilder, clusterId: uint16) =
  builder.clusterid = some(clusterId)

proc withShards*(builder: var WakuConfBuilder, shards: seq[uint16]) =
  builder.shards = some(shards)

proc withRelay*(builder: var WakuConfBuilder, relay: bool) =
  builder.relay = some(relay)

proc withMaxMessageSizeBytes*(builder: var WakuConfBuilder, maxMessageSizeBytes: int) =
  builder.maxMessageSizeBytes = some(maxMessageSizeBytes)

proc withDiscv5*(builder: var WakuConfBuilder, discv5: bool) =
  builder.discv5Conf.withDiscv5(discv5)

proc withTcpPort*(builder: var WakuConfBuilder, tcpPort: uint16) =
  builder.tcpPort = some(tcpPort.Port)

proc withDns4DomainName*(builder: var WakuConfBuilder, dns4DomainName: string) =
  builder.dns4DomainName = some(dns4DomainName.DomainName)

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

  let store =
    if builder.store.isSome:
      builder.store.get()
    else:
      warn "whether to mount store is not specified, defaulting to not mounting"
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

  # Apply cluster conf - values passed manually override cluster conf
  # Should be applied **first**, before individual values are pulled
  if builder.clusterConf.isSome:
    var clusterConf = builder.clusterConf.get()

    if builder.clusterId.isNone:
      builder.clusterId = some(clusterConf.clusterId)
    else:
      warn "Cluster id was manually provided alongside a cluster conf",
        used = builder.clusterId, discarded = clusterConf.clusterId

    if relay and clusterConf.rlnRelay:
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
  # Apply preset - end

  let nodeKey = ?nodeKey(builder, rng)

  let clusterId =
    if builder.clusterId.isSome:
      builder.clusterId.get()
    else:
      return err("Cluster Id is missing")

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

  let rlnRelayConf = builder.rlnRelayConf.build().valueOr:
    return err("RLN Relay Conf building failed: " & $error)

  let maxMessageSizeBytes =
    if builder.maxMessageSizeBytes.isSome:
      builder.maxMessageSizeBytes.get()
    else:
      return err("Max Message Size is missing")

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

  let tcpPort =
    if builder.tcpPort.isSome:
      builder.tcpPort.get()
    else:
      return err("TCP Port is missing")

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

  return ok(
    WakuConf(
      nodeKey: nodeKey,
      clusterId: clusterId,
      numShardsInNetwork: numShardsInNetwork,
      shards: shards,
      relay: relay,
      store: store,
      filter: filter,
      lightPush: lightPush,
      peerExchange: peerExchange,
      discv5Conf: discv5Conf,
      rlnRelayConf: rlnRelayConf,
      maxMessageSizeBytes: maxMessageSizeBytes,
      logLevel: logLevel,
      logFormat: logFormat,
      natStrategy: natStrategy,
      tcpPort: tcpPort,
      portsShift: portsShift,
      dns4DomainName: dns4DomainName,
      extMultiAddrs: extMultiAddrs,
    )
  )
