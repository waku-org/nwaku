import
  std/options,
  results,
  waku/factory/waku_conf,
  waku/factory/conf_builder/conf_builder,
  waku/factory/networks_config

type ShardingMode* = enum
  AutoSharding = "auto"
  StaticSharding = "static"

type AutoShardingConfig* = object
  numShardsInCluster*: uint16

type RlnConfig* = object
  contractAddress*: string
  chainId*: uint
  epochSizeSec*: uint64

type MessageValidation* = object
  maxMessageSizeBytes*: uint64
  rlnConfig*: Option[RlnConfig]

type NetworkConfig* = object
  bootstrapNodes*: seq[string]
  staticStoreNodes*: seq[string]
  clusterId*: uint16
  shardingMode*: Option[ShardingMode]
  autoShardingConfig*: Option[AutoShardingConfig]
  messageValidation*: Option[MessageValidation]

type WakuMode* = enum
  Edge = "edge"
  Relay = "relay"

type LibWakuConfig* = object
  mode*: WakuMode
  networkConfig*: Option[NetworkConfig]
  storeConfirmation*: bool
  ethRpcEndpoints*: seq[string]

proc DefaultShardingMode(): ShardingMode =
  return ShardingMode.Autosharding

proc DefaultAutoShardingConfig(): AutoShardingConfig =
  return AutoShardingConfig(numShardsInCluster: 1)

proc DefaultNetworkConfig(): NetworkConfig =
  return NetworkConfig(
    bootstrapNodes:
      @[
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      ],
    staticStoreNodes: @[], # TODO
    clusterId: 1,
    shardingMode: some(ShardingMode.AutoSharding),
    autoShardingConfig: some(AutoShardingConfig(numShardsInCluster: 8)),
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

proc toWakuConf*(config: LibWakuConfig): Result[WakuConf, string] =
  var b = WakuConfBuilder.init()

  case config.mode
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
  let networkConfig = config.networkConfig.get(DefaultNetworkConfig())

  # Set cluster ID
  b.withClusterId(networkConfig.clusterId)

  # Set sharding configuration
  case networkConfig.shardingMode.get(DefaultShardingMode())
  of AutoSharding:
    b.withShardingConf(ShardingConfKind.AutoSharding)
    let autoShardingConfig =
      networkConfig.autoShardingConfig.get(DefaultAutoShardingConfig())
    b.withNumShardsInCluster(autoShardingConfig.numShardsInCluster)
  of StaticSharding:
    b.withShardingConf(ShardingConfKind.StaticSharding)

  # Set bootstrap nodes
  if networkConfig.bootstrapNodes.len > 0:
    b.discv5Conf.withBootstrapNodes(networkConfig.bootstrapNodes)

  # TODO: verify behaviour
  # Set static store nodes
  if networkConfig.staticStoreNodes.len > 0:
    b.withStaticNodes(networkConfig.staticStoreNodes)

  # Set message validation

  let msgValidation = networkConfig.messageValidation.get(DefaultMessageValidation())
  b.withMaxMessageSize(msgValidation.maxMessageSizeBytes)

  # Set RLN config if provided
  if msgValidation.rlnConfig.isSome():
    let rlnConfig = msgValidation.rlnConfig.get()
    b.rlnRelayConf.withEnabled(true)
    b.rlnRelayConf.withEthContractAddress(rlnConfig.contractAddress)
    b.rlnRelayConf.withChainId(rlnConfig.chainId)
    b.rlnRelayConf.withEpochSizeSec(rlnConfig.epochSizeSec)
    b.rlnRelayConf.withDynamic(true)
    b.rlnRelayConf.withEthClientUrls(config.ethRpcEndpoints)

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
