import
  std/options,
  results,
  waku/factory/waku_conf,
  waku/factory/conf_builder/conf_builder,
  waku/factory/networks_config

type AutoShardingConfig* {.requiresInit.} = object
  numShardsInCluster*: uint16

type RlnConfig* {.requiresInit.} = object
  contractAddress*: string
  chainId*: uint
  epochSizeSec*: uint64

type MessageValidation* {.requiresInit.} = object
  maxMessageSizeBytes*: uint64
  rlnConfig*: Option[RlnConfig]

type WakuConfig* {.requiresInit.} = object
  bootstrapNodes: seq[string]
  staticStoreNodes: seq[string]
  clusterId: uint16
  autoShardingConfig: AutoShardingConfig
  messageValidation: MessageValidation

proc DefaultAutoShardingConfig(): AutoShardingConfig =
  return AutoShardingConfig(numShardsInCluster: 1)

proc DefaultMessageValidation(): MessageValidation =
  return MessageValidation(maxMessageSizeBytes: 153600, rlnConfig: none(RlnConfig))

proc newWakuConfig*(
    bootstrapNodes: seq[string],
    staticStoreNodes: seq[string] = @[],
    clusterId: uint16,
    autoShardingConfig: AutoShardingConfig = DefaultAutoShardingConfig(),
    messageValidation: MessageValidation = DefaultMessageValidation(),
): WakuConfig =
  return WakuConfig(
    bootstrapNodes: bootstrapNodes,
    staticStoreNodes: staticStoreNodes,
    clusterId: clusterId,
    autoShardingConfig: autoShardingConfig,
    messageValidation: messageValidation,
  )

proc DefaultWakuConfig(): WakuConfig =
  return WakuConfig(
    bootstrapNodes:
      @[
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      ],
    staticStoreNodes: @[], # TODO
    clusterId: 1,
    autoShardingConfig: AutoShardingConfig(numShardsInCluster: 8),
    messageValidation: MessageValidation(
      maxMessageSizeBytes: 153600,
      rlnConfig: some(
        RlnConfig(
          contractAddress: "0xB9cd878C90E49F797B4431fBF4fb333108CB90e6",
          chain_id: 59141,
          epoch_size_sec: 600, # 10 minutes
        )
      ),
    ),
  )

type WakuMode* = enum
  Edge = "edge"
  Relay = "relay"

type NodeConfig* {.requiresInit.} = object
  mode: WakuMode
  wakuConfig: WakuConfig
  storeConfirmation: bool
  ethRpcEndpoints: seq[string]

proc newNodeConfig*(
    mode: WakuMode = WakuMode.Relay,
    wakuConfig: WakuConfig = DefaultWakuConfig(),
    storeConfirmation: bool = true,
    ethRpcEndpoints: seq[string] = @[],
): NodeConfig =
  return NodeConfig(
    mode: mode,
    wakuConfig: wakuConfig,
    storeConfirmation: storeConfirmation,
    ethRpcEndpoints: ethRpcEndpoints,
  )

proc toWakuConf*(nodeConfig: NodeConfig): Result[WakuConf, string] =
  var b = WakuConfBuilder.init()

  case nodeConfig.mode
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
  let wakuConfig = nodeConfig.wakuConfig

  # Set cluster ID
  b.withClusterId(wakuConfig.clusterId)

  # Set sharding configuration
  b.withShardingConf(ShardingConfKind.AutoSharding)
  let autoShardingConfig = wakuConfig.autoShardingConfig
  b.withNumShardsInCluster(autoShardingConfig.numShardsInCluster)

  # Set bootstrap nodes
  if wakuConfig.bootstrapNodes.len > 0:
    b.discv5Conf.withBootstrapNodes(wakuConfig.bootstrapNodes)

  # TODO: verify behaviour
  # Set static store nodes
  if wakuConfig.staticStoreNodes.len > 0:
    b.withStaticNodes(wakuConfig.staticStoreNodes)

  # Set message validation

  let msgValidation = wakuConfig.messageValidation
  b.withMaxMessageSize(msgValidation.maxMessageSizeBytes)

  # Set RLN config if provided
  if msgValidation.rlnConfig.isSome():
    let rlnConfig = msgValidation.rlnConfig.get()
    b.rlnRelayConf.withEnabled(true)
    b.rlnRelayConf.withEthContractAddress(rlnConfig.contractAddress)
    b.rlnRelayConf.withChainId(rlnConfig.chainId)
    b.rlnRelayConf.withEpochSizeSec(rlnConfig.epochSizeSec)
    b.rlnRelayConf.withDynamic(true)
    b.rlnRelayConf.withEthClientUrls(nodeConfig.ethRpcEndpoints)

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
