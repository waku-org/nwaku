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
    builder.discv5Conf.withUdpPort(9000)
    builder.withRelayServiceRatio("50:50")
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withTreePath("/tmp/test-tree-path")

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == clusterConf.clusterId
    check conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    check conf.shards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(clusterConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == clusterConf.discv5BootstrapNodes

    if clusterConf.rlnRelay:
      assert conf.rlnRelayConf.isSome(), "RLN Relay conf is disabled"

      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress.string ==
        clusterConf.rlnRelayEthContractAddress
      check rlnRelayConf.dynamic == clusterConf.rlnRelayDynamic
      check rlnRelayConf.chainId == clusterConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == clusterConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == clusterConf.rlnRelayUserMessageLimit

  test "Cluster Conf is passed, but relay is disabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.withRelayServiceRatio("50:50")
    builder.discv5Conf.withUdpPort(9000)
    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withRelay(false)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == clusterConf.clusterId
    check conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    check conf.shards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(clusterConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == clusterConf.discv5BootstrapNodes

    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed, but rln relay is disabled":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()

    let # Mount all shards in network
      expectedShards = toSeq[0.uint16 .. 7.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.rlnRelayConf.withEnabled(false)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == clusterConf.clusterId
    check conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    check conf.shards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(clusterConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == clusterConf.discv5BootstrapNodes
    assert conf.rlnRelayConf.isNone

  test "Cluster Conf is passed and valid shards are specified":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 3.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withShards(shards)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == clusterConf.clusterId
    check conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    check conf.shards == shards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(clusterConf.maxMessageSize))
    check conf.discv5Conf.get().bootstrapNodes == clusterConf.discv5BootstrapNodes

  test "Cluster Conf is passed and invalid shards are specified":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    let shards = @[2.uint16, 10.uint16]

    ## Given
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")
    builder.withClusterConf(clusterConf)
    builder.withShards(shards)

    ## When
    let resConf = builder.build()

    ## Then
    assert resConf.isErr(), "Invalid shard was accepted"

  test "Cluster Conf is passed and RLN contract is overridden":
    ## Setup
    let clusterConf = ClusterConf.TheWakuNetworkConf()
    var builder = WakuConfBuilder.init()
    builder.rlnRelayConf.withEthClientAddress("https://my_eth_rpc_url/")

    # Mount all shards in network
    let expectedShards = toSeq[0.uint16 .. 7.uint16]
    let contractAddress = "0x0123456789ABCDEF"

    ## Given
    builder.rlnRelayConf.withEthContractAddress(contractAddress)
    builder.withClusterConf(clusterConf)
    builder.withRelay(true)
    builder.rlnRelayConf.withTreePath("/tmp/test")

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check conf.clusterId == clusterConf.clusterId
    check conf.numShardsInNetwork == clusterConf.numShardsInNetwork
    check conf.shards == expectedShards
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(clusterConf.maxMessageSize))
    check conf.discv5Conf.isSome == clusterConf.discv5Discovery
    check conf.discv5Conf.get().bootstrapNodes == clusterConf.discv5BootstrapNodes

    if clusterConf.rlnRelay:
      assert conf.rlnRelayConf.isSome

      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress.string == contractAddress
      check rlnRelayConf.dynamic == clusterConf.rlnRelayDynamic
      check rlnRelayConf.chainId == clusterConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == clusterConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == clusterConf.rlnRelayUserMessageLimit

suite "Waku Conf - node key":
  test "Node key is generated":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)

    ## Given

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
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

    ## Given
    builder.withNodeKey(nodeKey)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    assert utils.toHex(conf.nodeKey.getRawBytes().get()) ==
      utils.toHex(nodeKey.getRawBytes().get()),
      "Passed node key isn't in config:" & $nodeKey & $conf.nodeKey

suite "Waku Conf - extMultiaddrs":
  test "Valid multiaddresses are passed and accepted":
    ## Setup
    var builder = WakuConfBuilder.init()
    builder.withClusterId(1)

    ## Given
    let multiaddrs =
      @["/ip4/127.0.0.1/udp/9090/quic", "/ip6/::1/tcp/3217", "/dns4/foo.com/tcp/80"]
    builder.withExtMultiAddrs(multiaddrs)

    ## When
    let resConf = builder.build()
    assert resConf.isOk(), $resConf.error
    let conf = resConf.get()

    ## Then
    let resValidate = conf.validate()
    assert resValidate.isOk(), $resValidate.error
    check multiaddrs.len == conf.networkConf.extMultiAddrs.len
    let resMultiaddrs = conf.networkConf.extMultiAddrs.map(
      proc(m: MultiAddress): string =
        $m
    )
    for m in multiaddrs:
      check m in resMultiaddrs
