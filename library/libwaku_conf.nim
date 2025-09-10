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

type MessageValidation* = object
  maxMessageSizeBytes*: uint64
  rlnConfig*: Option[RlnConfig]

type NetworkConf* = object
  bootstrapNodes*: seq[string]
  staticStoreNodes*: seq[string]
  clusterId*: uint16
  shardingMode*: Option[ShardingMode]
  autoShardingConf*: Option[AutoShardingConf]
  messageValidation*: Option[MessageValidation]

type WakuMode* = enum
  Edge = "edge"
  Relay = "relay"

type LibWakuConf* = object
  mode*: WakuMode
  networkConf*: Option[NetworkConf]
  storeConfirmation*: bool
  ethRpcEndpoints*: seq[string]

proc DefaultShardingMode(): ShardingMode =
  return ShardingMode.Autosharding

proc DefaultAutoShardingConf(): AutoShardingConf =
  return AutoShardingConf(numShardsInCluster: 1)

proc DefaultNetworkConf(): NetworkConf =
  return NetworkConf(
    bootstrapNodes:
      @[
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      ],
    staticStoreNodes: @[], # TODO
    clusterId: 1,
    shardingMode: some(ShardingMode.AutoSharding),
    autoShardingConf: some(AutoShardingConf(numShardsInCluster: 8)),
    messageValidation: some(
      MessageValidation(
        maxMessageSizeBytes: 153600,
        rlnConfig: some (
          RlnConfig(
            contractAddress: "0xB9cd878C90E49F797B4431fBF4fb333108CB90e6",
            chain_id: 59141,
            epoch_size_sec: 600, # 10 minutes
          )
        ),
      )
    ),
  )

proc DefaultMessageValidation(): MessageValidation =
  return MessageValidation(maxMessageSizeBytes: 153600, rlnConfig: none(RlnConfig))

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
  let networkConf = libConf.networkConf.get(DefaultNetworkConf())

  # Set cluster ID
  b.withClusterId(networkConf.clusterId)

  # Set sharding configuration
  case networkConf.shardingMode.get(DefaultShardingMode())
  of AutoSharding:
    b.withShardingConf(ShardingConfKind.AutoSharding)
    let autoShardingConf = networkConf.autoShardingConf.get(DefaultAutoShardingConf())
    b.withNumShardsInCluster(autoShardingConf.numShardsInCluster)
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

  let msgValidation = networkConf.messageValidation.get(DefaultMessageValidation())
  b.withMaxMessageSize(msgValidation.maxMessageSizeBytes)

  # Set RLN config if provided
  if msgValidation.rlnConfig.isSome():
    let rlnConfig = msgValidation.rlnConfig.get()
    b.rlnRelayConf.withEnabled(true)
    b.rlnRelayConf.withEthContractAddress(rlnConfig.contractAddress)
    b.rlnRelayConf.withChainId(rlnConfig.chainId)
    b.rlnRelayConf.withEpochSizeSec(rlnConfig.epochSizeSec)
    b.rlnRelayConf.withDynamic(true)
    b.rlnRelayConf.withEthClientUrls(libConf.ethRpcEndpoints)

    # TODO: we should get rid of those two
    b.rlnRelayconf.withUserMessageLimit(100)
    b.rlnRelayConf.withTreePath("./rln_tree")

  ## Various configurations
  b.withNatStrategy("any")

  let wakuConf = b.build().valueOr:
    return err("Failed to build configuration: " & error)

  wakuConf.validate().isOkOr:
    return err("Failed to validate configuration: " & error)

  return ok(wakuConf)
