import
  std/options,
  results,
  waku/factory/waku_conf,
  waku/factory/conf_builder/conf_builder,
  waku/factory/networks_config

type ShardingMode* = enum
  AutoSharding = "auto"
  StaticSharding = "static"

type AutoShardingConf* = object
  numShardsInCluster*: uint16

type RlnConfig* = object
  contractAddress*: string
  chainId*: uint
  epochSizeSec*: uint64
  rpcApiUrls*: seq[string]

type MessageValidation* = object
  maxMessageSizeBytes*: uint64
  rlnConfig*: Option[RlnConfig]

type NetworkConf* = object
  bootstrapNodes*: seq[string]
  staticStoreNodes*: seq[string]
  clusterId*: uint16
  shardingMode*: ShardingMode
  autoShardingConf*: Option[AutoShardingConf]
  messageValidation*: Option[MessageValidation]

type WakuMode* = enum
  Edge = "edge"
  Relay = "relay"

type LibWakuConf* = object
  mode*: WakuMode
  networkConf*: NetworkConf
  storeConfirmation*: bool

proc toWakuConf*(libConf: LibWakuConf): Result[WakuConf, string] =
  var b = WakuConfBuilder.init()

  case libConf.mode
  of Relay:
    b.withRelay(true)

    b.filterServiceConf.withEnabled(true)
    b.filterServiceConf.withMaxPeersToServe(20)

    b.withLightPush(true)

    b.discv5Conf.withEnabled(true)
    b.withPeerExchange(true)

    b.rateLimitConf.withRateLimits(@["filter:100/1s", "lightpush:5/1s", "px:5/1s"])
  of Edge:
    return err("Edge mode is not implemented")

  #TODO: store confirmation

  ## Network Conf
  let networkConf = libConf.networkConf

  # Set cluster ID
  b.withClusterId(networkConf.clusterId)

  # Set sharding configuration
  case networkConf.shardingMode
  of AutoSharding:
    b.withShardingConf(ShardingConfKind.AutoSharding)
    if networkConf.autoShardingConf.isSome():
      let autoConf = networkConf.autoShardingConf.get()
      b.withNumShardsInCluster(autoConf.numShardsInCluster)
  of StaticSharding:
    b.withShardingConf(ShardingConfKind.StaticSharding)

  # Set bootstrap nodes
  if networkConf.bootstrapNodes.len > 0:
    b.discv5Conf.withBootstrapNodes(networkConf.bootstrapNodes)

  # TODO: verify behaviour
  # Set static store nodes
  if networkConf.staticStoreNodes.len > 0:
    b.withStaticNodes(networkConf.staticStoreNodes)

  # Set message validation
  if networkConf.messageValidation.isSome():
    let msgValidation = networkConf.messageValidation.get()
    b.withMaxMessageSize(msgValidation.maxMessageSizeBytes)

    # Set RLN config if provided
    if msgValidation.rlnConfig.isSome():
      let rlnConfig = msgValidation.rlnConfig.get()
      b.rlnRelayConf.withEnabled(true)
      b.rlnRelayConf.withEthContractAddress(rlnConfig.contractAddress)
      b.rlnRelayConf.withChainId(rlnConfig.chainId)
      b.rlnRelayConf.withEpochSizeSec(rlnConfig.epochSizeSec)
      b.rlnRelayConf.withDynamic(true)
      b.rlnRelayConf.withEthClientUrls(rlnConfig.rpcApiUrls)

  ## Various configurations
  b.withNatStrategy("any")

  return b.build()
