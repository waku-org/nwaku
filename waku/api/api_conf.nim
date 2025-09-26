import std/[net, options]

import results

import
  waku/common/utils/parse_size_units,
  waku/factory/waku_conf,
  waku/factory/conf_builder/conf_builder,
  waku/factory/networks_config

type AutoShardingConfig* {.requiresInit.} = object
  numShardsInCluster*: uint16

type RlnConfig* {.requiresInit.} = object
  contractAddress*: string
  chainId*: uint
  epochSizeSec*: uint64

type NetworkingConfig* {.requiresInit.} = object
  listenIpv4*: string
  p2pTcpPort*: uint16
  discv5UdpPort*: uint16

type MessageValidation* {.requiresInit.} = object
  maxMessageSize*: string # Accepts formats like "150 KiB", "1500 B"
  rlnConfig*: Option[RlnConfig]

type WakuConfig* {.requiresInit.} = object
  entryNodes: seq[string]
  staticStoreNodes: seq[string]
  clusterId: uint16
  autoShardingConfig: AutoShardingConfig
  messageValidation: MessageValidation

proc DefaultNetworkingConfig(): NetworkingConfig =
  return NetworkingConfig(listenIpv4: "0.0.0.0", p2pTcpPort: 60000, discv5UdpPort: 9000)

proc DefaultAutoShardingConfig(): AutoShardingConfig =
  return AutoShardingConfig(numShardsInCluster: 1)

proc DefaultMessageValidation(): MessageValidation =
  return MessageValidation(maxMessageSize: "150 KiB", rlnConfig: none(RlnConfig))

proc newWakuConfig*(
    entryNodes: seq[string],
    staticStoreNodes: seq[string] = @[],
    clusterId: uint16,
    autoShardingConfig: AutoShardingConfig = DefaultAutoShardingConfig(),
    messageValidation: MessageValidation = DefaultMessageValidation(),
): WakuConfig =
  return WakuConfig(
    entryNodes: entryNodes,
    staticStoreNodes: staticStoreNodes,
    clusterId: clusterId,
    autoShardingConfig: autoShardingConfig,
    messageValidation: messageValidation,
  )

proc TheWakuNetworkPreset(): WakuConfig =
  return WakuConfig(
    entryNodes:
      @[
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      ],
    staticStoreNodes: @[],
    clusterId: 1,
    autoShardingConfig: AutoShardingConfig(numShardsInCluster: 8),
    messageValidation: MessageValidation(
      maxMessageSize: "150 KiB",
      rlnConfig: some(
        RlnConfig(
          contractAddress: "0xB9cd878C90E49F797B4431fBF4fb333108CB90e6",
          chainId: 59141,
          epochSizeSec: 600, # 10 minutes
        )
      ),
    ),
  )

type WakuMode* = enum
  Edge = "edge"
  Sovereign = "sovereign"

type NodeConfig* {.requiresInit.} = object
  mode: WakuMode
  wakuConfig: WakuConfig
  messageConfirmation: bool
  networkingConfig: NetworkingConfig
  ethRpcEndpoints: seq[string]

proc newNodeConfig*(
    mode: WakuMode = WakuMode.Sovereign,
    wakuConfig: WakuConfig = TheWakuNetworkPreset(),
    messageConfirmation: bool = true,
    networkingConfig: NetworkingConfig = DefaultNetworkingConfig(),
    ethRpcEndpoints: seq[string] = @[],
): NodeConfig =
  return NodeConfig(
    mode: mode,
    wakuConfig: wakuConfig,
    messageConfirmation: messageConfirmation,
    networkingConfig: networkingConfig,
    ethRpcEndpoints: ethRpcEndpoints,
  )

proc toWakuConf*(nodeConfig: NodeConfig): Result[WakuConf, string] =
  var b = WakuConfBuilder.init()

  # Apply networking configuration
  let networkingConfig = nodeConfig.networkingConfig
  let ip = parseIpAddress(networkingConfig.listenIpv4)

  b.withP2pListenAddress(ip)
  b.withP2pTcpPort(networkingConfig.p2pTcpPort)
  b.discv5Conf.withUdpPort(networkingConfig.discv5UdpPort)

  case nodeConfig.mode
  of Sovereign:
    b.withRelay(true)

    # Metadata is always mounted

    b.filterServiceConf.withEnabled(true)
    b.filterServiceConf.withMaxPeersToServe(20)

    b.withLightPush(true)

    b.discv5Conf.withEnabled(true)
    b.withPeerExchange(true)
    b.withRendezvous(true)

    # TODO: fix store as client usage

    b.rateLimitConf.withRateLimits(@["filter:100/1s", "lightpush:5/1s", "px:5/1s"])
  of Edge:
    return err("Edge mode is not implemented")

  # Configure message confirmation
  #if nodeConfig.messageConfirmation:
  # TODO: Implement store-based reliability for publishing
  # As per spec: When set to true, Store-based reliability for publishing SHOULD be enabled, filter-based reliability MAY be used

  ## Network Conf
  let wakuConfig = nodeConfig.wakuConfig

  # Set cluster ID
  b.withClusterId(wakuConfig.clusterId)

  # Set sharding configuration
  b.withShardingConf(ShardingConfKind.AutoSharding)
  let autoShardingConfig = wakuConfig.autoShardingConfig
  b.withNumShardsInCluster(autoShardingConfig.numShardsInCluster)

  # set bootstrap nodes
  if wakuConfig.entryNodes.len > 0:
    #TODO: make it accept multiaddress too
    b.discv5Conf.withBootstrapNodes(wakuConfig.entryNodes)

  # TODO: verify behaviour
  # Set static store nodes
  if wakuConfig.staticStoreNodes.len > 0:
    b.withStaticNodes(wakuConfig.staticStoreNodes)

  # Set message validation
  let msgValidation = wakuConfig.messageValidation
  let maxSizeBytes = parseMsgSize(msgValidation.maxMessageSize).valueOr:
    return err("Failed to parse max message size: " & error)
  b.withMaxMessageSize(maxSizeBytes)

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
