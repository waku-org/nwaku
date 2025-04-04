{.used.}

import
  libp2p/crypto/[crypto, secp],
  nimcrypto/utils,
  std/[options, sequtils],
  results,
  testutils/unittests
import
  waku/factory/waku_conf,
  waku/factory/networks_config,
  waku/common/utils/parse_size_units

suite "Waku Conf - build with cluster conf":
  test "Cluster Conf is passed and relay is enabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.withRlnRelayEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withRelay(true)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))

    assert conf.discv5BootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    if clusterConf.rlnRelay:
      assert conf.rlnRelayConf.isSome

      let rlnRelayConf = conf.rlnRelayConf.get()
      assert rlnRelayConf.rlnRelayEthContractAddress.string ==
        clusterConf.rlnRelayEthContractAddress
      assert rlnRelayConf.rlnRelayDynamic == clusterConf.rlnRelayDynamic
      assert rlnRelayConf.rlnRelayChainId == clusterConf.rlnRelayChainId
      assert rlnRelayConf.rlnRelayBandwidthThreshold ==
        clusterConf.rlnRelayBandwidthThreshold
      assert rlnRelayConf.rlnEpochSizeSec == clusterConf.rlnEpochSizeSec
      assert rlnRelayConf.rlnRelayUserMessageLimit ==
        clusterConf.rlnRelayUserMessageLimit

  test "Cluster Conf is passed, but relay is disabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()

    let # Mount all shards in network
      expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.withRlnRelayEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withRelay(false)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))
    assert conf.discv5BootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed, but rln relay is disabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()

    let # Mount all shards in network
      expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.withRlnRelayEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withRlnRelay(false)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))
    assert conf.discv5BootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed and valid shards are specified":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 3.uint16]

    ## Given
    builder.withRlnRelayEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withShards(shards)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == shards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))
    assert conf.discv5BootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

  test "Cluster Conf is passed and invalid shards are specified":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 10.uint16]

    ## Given
    builder.withRlnRelayEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withShards(shards)

    ## When
    let res = builder.build()

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

  test "Cluster Conf is passed and RLN contract is overridden":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]
    let contractAddress = "0x0123456789ABCDEF"

    ## Given
    builder.withRlnRelayEthClientAddress("https://my_eth_rpc_url/")
    builder.withRlnRelayEthContractAddress(contractAddress)
    builder.withClusterConf(clusterConf)
    builder.withRelay(true)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.clusterId == clusterConf.clusterId
    assert conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    assert conf.shards == expectedShards
    assert conf.maxMessageSizeBytes ==
      int(parseCorrectMsgSize(clusterConf.maxMessageSize))

    assert conf.discv5BootstrapNodes.map(
      proc(e: TextEnr): string =
        e.string
    ) == clusterConf.discv5BootstrapNodes

    if clusterConf.rlnRelay:
      assert conf.rlnRelayConf.isSome

      let rlnRelayConf = conf.rlnRelayConf.get()
      assert rlnRelayConf.rlnRelayEthContractAddress.string == contractAddress
      assert rlnRelayConf.rlnRelayDynamic == clusterConf.rlnRelayDynamic
      assert rlnRelayConf.rlnRelayChainId == clusterConf.rlnRelayChainId
      assert rlnRelayConf.rlnRelayBandwidthThreshold ==
        clusterConf.rlnRelayBandwidthThreshold
      assert rlnRelayConf.rlnEpochSizeSec == clusterConf.rlnEpochSizeSec
      assert rlnRelayConf.rlnRelayUserMessageLimit ==
        clusterConf.rlnRelayUserMessageLimit

suite "Waku Conf - node key":
  test "Node key is generated":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)
    builder.withMaxMessageSizeBytes(1)

    ## Given

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error
    let conf = res.get()

    ## Then
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

    ## Given
    builder.withNodeKey(nodeKey)

    ## When
    let res = builder.build()
    assert res.isOk(), $res.error
    let conf = res.get()

    ## Then
    assert utils.toHex(conf.nodeKey.getRawBytes().get()) ==
      utils.toHex(nodeKey.getRawBytes().get()),
      "Passed node key isn't in config:" & $nodeKey & $conf.nodeKey
