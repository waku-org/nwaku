{.used.}

import
  libp2p/crypto/[crypto, secp],
  libp2p/multiaddress,
  nimcrypto/utils,
  std/[options, sequtils],
  results,
  testutils/unittests
import
  waku/factory/waku_conf,
  waku/factory/waku_conf_builder,
  waku/factory/networks_config,
  waku/common/utils/parse_size_units

suite "Waku Conf - build with cluster conf":
  test "Cluster Conf is passed and relay is enabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withRelay(true)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.validate().isOk()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))

    assert conf.discv5Conf.get().bootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    if clusterConf.rlnRelay:
      assert conf.rlnRelayConf.isSome

      let rlnRelayConf = conf.rlnRelayConf.get()
      assert rlnRelayConf.ethContractAddress.string ==
        clusterConf.rlnRelayEthContractAddress
      assert rlnRelayConf.dynamic == clusterConf.rlnRelayDynamic
      assert rlnRelayConf.chainId == clusterConf.rlnRelayChainId
      assert rlnRelayConf.bandwidthThreshold == clusterConf.rlnRelayBandwidthThreshold
      assert rlnRelayConf.epochSizeSec == clusterConf.rlnEpochSizeSec
      assert rlnRelayConf.userMessageLimit == clusterConf.rlnRelayUserMessageLimit

  test "Cluster Conf is passed, but relay is disabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withRelay(false)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.validate().isOk()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))
    assert conf.discv5Conf.get().bootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed, but rln relay is disabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)

    let # Mount all shards in network
      expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.rlnRelayConf.withRlnRelay(false)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.validate().isOk()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))
    assert conf.discv5Conf.get().bootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed and valid shards are specified":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)
    let shards = @[2.uint16, 3.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withShards(shards)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.validate().isOk()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == shards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))
    assert conf.discv5Conf.get().bootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

  test "Cluster Conf is passed and invalid shards are specified":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)
    let shards = @[2.uint16, 10.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withShards(shards)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.validate().isErr(), "Invalid shard was accepted"

  test "Cluster Conf is passed and RLN contract is overridden":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")

    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]
    let contractAddress = "0x0123456789ABCDEF"

    ## Given
    builder.rlnRelayConf.withEthContractAddress(contractAddress)
    builder.withClusterConf(clusterConf)
    builder.withRelay(true)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.validate().isOk()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))

    assert conf.discv5Conf.get().bootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    if clusterConf.rlnRelay:
      assert conf.rlnRelayConf.isSome

      let rlnRelayConf = conf.rlnRelayConf.get()
      assert rlnRelayConf.ethContractAddress.string == contractAddress
      assert rlnRelayConf.dynamic == clusterConf.rlnRelayDynamic
      assert rlnRelayConf.chainId == clusterConf.rlnRelayChainId
      assert rlnRelayConf.bandwidthThreshold == clusterConf.rlnRelayBandwidthThreshold
      assert rlnRelayConf.epochSizeSec == clusterConf.rlnEpochSizeSec
      assert rlnRelayConf.userMessageLimit == clusterConf.rlnRelayUserMessageLimit

suite "Waku Conf - node key":
  test "Node key is generated":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)
    builder.withMaxMessageSizeBytes(1)
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)

    ## Given

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error
    let conf = res.get()

    ## Then
    assert conf.validate().isOk()
    let pubkey = getPublicKey(conf.nodeKey)
    assert pubkey.isOk()

  test "Passed node key is used":
    ## Setup
    let nodeKeyStr =
      "0011223344556677889900aabbccddeeff0011223344556677889900aabbccddeeff"
    let nodeKey = block:
      let key = SkPrivateKey.init(utils.fromHex(nodeKeyStr)).tryGet()
      crypto.PrivateKey(scheme: Secp256k1, skkey: key)
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)
    builder.withMaxMessageSizeBytes(1)
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)

    ## Given
    builder.withNodeKey(nodeKey)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error
    let conf = res.get()

    ## Then
    assert conf.validate().isOk()
    assert utils.toHex(conf.nodeKey.getRawBytes().get()) ==
      utils.toHex(nodeKey.getRawBytes().get()),
      "Passed node key isn't in config:" & $nodeKey & $conf.nodeKey

suite "Waku Conf - extMultiaddrs":
  test "Valid multiaddresses are passed and accepted":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)
    builder.withMaxMessageSizeBytes(1)
    builder.withTcpPort(60000)
    builder.discv5Conf.withUdpPort(9000)

    ## Given
    let multiaddrs =
      @["/ip4/127.0.0.1/udp/9090/quic", "/ip6/::1/tcp/3217", "/dns4/foo.com/tcp/80"]
    for m in multiaddrs:
      builder.withExtMultiAddr(m)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error
    let conf = res.get()

    ## Then
    assert conf.validate().isOk()
    assert multiaddrs.len == conf.extMultiaddrs.len
    let resMultiaddrs = conf.extMultiaddrs.map(
      proc(m: MultiAddress): string =
        $m
    )
    for m in multiaddrs:
      assert m in resMultiaddrs
