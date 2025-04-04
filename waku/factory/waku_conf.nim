import std/[options, sequtils, net], chronicles, libp2p/crypto/crypto, results

import ../common/logging, ../common/utils/parse_size_units

import waku/factory/networks_config

logScope:
  topics = "wakunode conf"

type
  TextEnr* = distinct string
  ContractAddress* = distinct string
  EthRpcUrl* = distinct string
  NatStrategy* = distinct string

# TODO: this should come from RLN relay module
type RlnRelayConf* = ref object
  rlnRelayEthContractAddress*: ContractAddress
  rlnRelayChainId*: uint
  rlnRelayDynamic*: bool
  rlnRelayBandwidthThreshold*: int
  rlnEpochSizeSec*: uint64
  rlnRelayUserMessageLimit*: uint64
  rlnRelayEthClientAddress*: EthRpcUrl

type WakuConf* = ref object
  nodeKey*: PrivateKey

  clusterId*: uint16
  numShardsInNetwork*: uint32
  shards*: seq[uint16]

  relay*: bool
  store*: bool
  filter*: bool
  lightPush*: bool
  peerExchange*: bool

  discv5BootstrapNodes*: seq[TextEnr]

  rlnRelayConf*: Option[RlnRelayConf]

  maxMessageSizeBytes*: int

  logLevel*: logging.LogLevel
  logFormat*: logging.LogFormat

  natStrategy*: NatStrategy

  tcpPort*: Port
  portsShift*: uint16

proc log*(conf: WakuConf) =
  info "Configuration: Enabled protocols",
    relay = conf.relay,
    rlnRelay = conf.rlnRelayConf.isSome,
    store = conf.store,
    filter = conf.filter,
    lightPush = conf.lightPush,
    peerExchange = conf.peerExchange

  info "Configuration. Network", cluster = conf.clusterId

  for shard in conf.shards:
    info "Configuration. Shards", shard = shard

  for i in conf.discv5BootstrapNodes:
    info "Configuration. Bootstrap nodes", node = i.string

  if conf.rlnRelayConf.isSome:
    var rlnRelayConf = conf.rlnRelayConf.geT()
    if rlnRelayConf.rlnRelayDynamic:
      info "Configuration. Validation",
        mechanism = "onchain rln",
        contract = rlnRelayConf.rlnRelayEthContractAddress.string,
        maxMessageSize = conf.maxMessageSizeBytes,
        rlnEpochSizeSec = rlnRelayConf.rlnEpochSizeSec,
        rlnRelayUserMessageLimit = rlnRelayConf.rlnRelayUserMessageLimit,
        rlnRelayEthClientAddress = string(rlnRelayConf.rlnRelayEthClientAddress)

type RlnRelayConfBuilder = ref object
  rlnRelay: Option[bool]
  rlnRelayEthContractAddress: Option[ContractAddress]
  rlnRelayChainId: Option[uint]
  rlnRelayDynamic: Option[bool]
  rlnRelayBandwidthThreshold: Option[int]
  rlnEpochSizeSec: Option[uint64]
  rlnRelayUserMessageLimit: Option[uint64]
  rlnRelayEthClientAddress: Option[EthRpcUrl]

proc init(T: type RlnRelayConfBuilder): RlnRelayConfBuilder =
  RlnRelayConfBuilder()

proc withRlnRelay(builder: var RlnRelayConfBuilder, rlnRelay: bool) =
  builder.rlnRelay = some(rlnRelay)

proc withRlnRelayEthClientAddress(
    builder: var RlnRelayConfBuilder, rlnRelayEthClientAddress: EthRpcUrl
) =
  builder.rlnRelayEthClientAddress = some(rlnRelayEthClientAddress)

proc withRlnRelayEthContractAddress(
    builder: var RlnRelayConfBuilder, withRlnRelayEthContractAddress: ContractAddress
) =
  builder.rlnRelayEthContractAddress = some(withRlnRelayEthContractAddress)

proc build(builder: RlnRelayConfBuilder): Result[Option[RlnRelayConf], string] =
  if builder.rlnRelay.isNone or not builder.rlnRelay.get():
    info "RLN Relay is disabled"
    return ok(none(RlnRelayConf))

  let rlnRelayEthContractAddress =
    if builder.rlnRelayEthContractAddress.isSome:
      builder.rlnRelayEthContractAddress.get()
    else:
      return err("RLN Eth Contract Address was not specified")

  let rlnRelayChainId =
    if builder.rlnRelayChainId.isSome:
      builder.rlnRelayChainId.get()
    else:
      return err("RLN Relay Chain Id was not specified")

  let rlnRelayDynamic =
    if builder.rlnRelayDynamic.isSome:
      builder.rlnRelayDynamic.get()
    else:
      return err("RLN Relay Dynamic was not specified")

  let rlnRelayBandwidthThreshold =
    if builder.rlnRelayBandwidthThreshold.isSome:
      builder.rlnRelayBandwidthThreshold.get()
    else:
      return err("RLN Relay Bandwidth Threshold was not specified")

  let rlnEpochSizeSec =
    if builder.rlnEpochSizeSec.isSome:
      builder.rlnEpochSizeSec.get()
    else:
      return err("RLN Epoch Size was not specified")

  let rlnRelayUserMessageLimit =
    if builder.rlnRelayUserMessageLimit.isSome:
      builder.rlnRelayUserMessageLimit.get()
    else:
      return err("RLN Relay User Message Limit was not specified")

  let rlnRelayEthClientAddress =
    if builder.rlnRelayEthClientAddress.isSome:
      builder.rlnRelayEthClientAddress.get()
    else:
      return err("RLN Relay Eth Client Address was not specified")

  return ok(
    some(
      RlnRelayConf(
        rlnRelayChainId: rlnRelayChainId,
        rlnRelayDynamic: rlnRelayDynamic,
        rlnRelayEthContractAddress: rlnRelayEthContractAddress,
        rlnEpochSizeSec: rlnEpochSizeSec,
        rlnRelayUserMessageLimit: rlnRelayUserMessageLimit,
        rlnRelayEthClientAddress: rlnRelayEthClientAddress,
      )
    )
  )

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

  rlnRelayConf: RlnRelayConfBuilder

  maxMessageSizeBytes: Option[int]

  discv5Discovery: Option[bool]
  discv5BootstrapNodes: Option[seq[TextEnr]]

  logLevel: Option[logging.LogLevel]
  logFormat: Option[logging.LogFormat]

  natStrategy: Option[NatStrategy]

  tcpPort: Option[Port]
  portsShift: Option[uint16]

proc init*(T: type WakuConfBuilder): WakuConfBuilder =
  WakuConfBuilder(rlnRelayConf: RlnRelayConfBuilder.init())

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

proc withRlnRelay*(builder: var WakuConfBuilder, rlnRelay: bool) =
  builder.rlnRelayConf.withRlnRelay(rlnRelay)

proc withRlnRelayEthClientAddress*(
    builder: var WakuConfBuilder, rlnRelayEthClientAddress: string
) =
  builder.rlnRelayConf.withRlnRelayEthClientAddress(rlnRelayEthClientAddress.EthRpcUrl)

proc withRlnRelayEthContractAddress*(
    builder: var WakuConfBuilder, rlnRelayEthContractAddress: string
) =
  builder.rlnRelayConf.withRlnRelayEthContractAddress(
    rlnRelayEthContractAddress.ContractAddress
  )

proc withMaxMessageSizeBytes*(builder: WakuConfBuilder, maxMessageSizeBytes: int) =
  builder.maxMessageSizeBytes = some(maxMessageSizeBytes)

proc withTcpPort*(builder: WakuConfBuilder, tcpPort: uint16) =
  builder.tcpPort = some(tcpPort.Port)

proc validateShards*(wakuConf: WakuConf): Result[void, string] =
  let numShardsInNetwork = wakuConf.numShardsInNetwork

  for shard in wakuConf.shards:
    if shard >= numShardsInNetwork:
      let msg =
        "validateShards invalid shard: " & $shard & " when numShardsInNetwork: " &
        $numShardsInNetwork # fmt doesn't work
      error "validateShards failed", error = msg
      return err(msg)

  return ok()

proc validate(wakuConf: WakuConf): Result[void, string] =
  ?validateShards(wakuConf)

  return ok()

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
        rlnRelayConf.rlnRelay = some(true)
      else:
        warn "RLN Relay was manually provided alongside a cluster conf",
          used = rlnRelayConf.rlnRelay, discarded = clusterConf.rlnRelay

      if rlnRelayConf.rlnRelayEthContractAddress.isNone:
        rlnRelayConf.rlnRelayEthContractAddress =
          some(clusterConf.rlnRelayEthContractAddress.ContractAddress)
      else:
        warn "RLN Relay ETH Contract Address was manually provided alongside a cluster conf",
          used = rlnRelayConf.rlnRelayEthContractAddress.get().string,
          discarded = clusterConf.rlnRelayEthContractAddress.string

      if rlnRelayConf.rlnRelayChainId.isNone:
        rlnRelayConf.rlnRelayChainId = some(clusterConf.rlnRelayChainId)
      else:
        warn "RLN Relay Chain Id was manually provided alongside a cluster conf",
          used = rlnRelayConf.rlnRelayChainId, discarded = clusterConf.rlnRelayChainId

      if rlnRelayConf.rlnRelayDynamic.isNone:
        rlnRelayConf.rlnRelayDynamic = some(clusterConf.rlnRelayDynamic)
      else:
        warn "RLN Relay Dynamic was manually provided alongside a cluster conf",
          used = rlnRelayConf.rlnRelayDynamic, discarded = clusterConf.rlnRelayDynamic

      if rlnRelayConf.rlnRelayBandwidthThreshold.isNone:
        rlnRelayConf.rlnRelayBandwidthThreshold =
          some(clusterConf.rlnRelayBandwidthThreshold)
      else:
        warn "RLN Relay Bandwidth Threshold was manually provided alongside a cluster conf",
          used = rlnRelayConf.rlnRelayBandwidthThreshold,
          discarded = clusterConf.rlnRelayBandwidthThreshold

      if rlnRelayConf.rlnEpochSizeSec.isNone:
        rlnRelayConf.rlnEpochSizeSec = some(clusterConf.rlnEpochSizeSec)
      else:
        warn "RLN Epoch Size in Seconds was manually provided alongside a cluster conf",
          used = rlnRelayConf.rlnEpochSizeSec, discarded = clusterConf.rlnEpochSizeSec

      if rlnRelayConf.rlnRelayUserMessageLimit.isNone:
        rlnRelayConf.rlnRelayUserMessageLimit =
          some(clusterConf.rlnRelayUserMessageLimit)
      else:
        warn "RLN Relay Dynamic was manually provided alongside a cluster conf",
          used = rlnRelayConf.rlnRelayUserMessageLimit,
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

    if builder.discv5Discovery.isNone:
      builder.discv5Discovery = some(clusterConf.discv5Discovery)

    if builder.discv5BootstrapNodes.isNone:
      builder.discv5BootstrapNodes = some(
        clusterConf.discv5BootstrapNodes.map(
          proc(e: string): TextEnr =
            e.TextEnr
        )
      )
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

  let discv5BootstrapNodes =
    if builder.discv5BootstrapNodes.isSome:
      builder.discv5BootstrapNodes.get()
    else:
      @[]

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

  let wakuConf = WakuConf(
    nodeKey: nodeKey,
    clusterId: clusterId,
    numShardsInNetwork: numShardsInNetwork,
    shards: shards,
    relay: relay,
    store: store,
    filter: filter,
    lightPush: lightPush,
    peerExchange: peerExchange,
    discv5BootstrapNodes: discv5BootstrapNodes,
    rlnRelayConf: rlnRelayConf,
    maxMessageSizeBytes: maxMessageSizeBytes,
    logLevel: logLevel,
    logFormat: logFormat,
    natStrategy: natStrategy,
    tcpPort: tcpPort,
    portsShift: portsShift,
  )

  ?validate(wakuConf)

  return ok(wakuConf)
