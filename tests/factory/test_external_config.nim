{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  libp2p/crypto/[crypto, secp],
  libp2p/multiaddress,
  nimcrypto/utils,
  secp256k1,
  confutils
import
  ../../waku/factory/external_config,
  ../../waku/factory/networks_config,
  ../../waku/factory/waku_conf,
  ../../waku/common/logging,
  ../../waku/common/utils/parse_size_units

suite "Waku config - apply preset":
  test "Default preset is TWN":
    ## Setup
    let expectedConf = ClusterConf.TheWakuNetworkConf()

    ## Given
    let preConfig = WakuNodeConf(
      cmd: noCommand,
      preset: "twn",
      relay: true,
      ethClientUrls: @["http://someaddress".EthRpcUrl],
      rlnRelayTreePath: "/tmp/sometreepath",
    )

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(expectedConf.maxMessageSize))
    check conf.clusterId == expectedConf.clusterId
    check conf.rlnRelayConf.isSome() == expectedConf.rlnRelay
    if conf.rlnRelayConf.isSome():
      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress == expectedConf.rlnRelayEthContractAddress
      check rlnRelayConf.dynamic == expectedConf.rlnRelayDynamic
      check rlnRelayConf.chainId == expectedConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == expectedConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == expectedConf.rlnRelayUserMessageLimit
    check conf.numShardsInNetwork == expectedConf.numShardsInNetwork
    check conf.discv5Conf.isSome() == expectedConf.discv5Discovery
    if conf.discv5Conf.isSome():
      let discv5Conf = conf.discv5Conf.get()
      check discv5Conf.bootstrapNodes == expectedConf.discv5BootstrapNodes

  test "Subscribes to all valid shards in twn":
    ## Setup
    let expectedConf = ClusterConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 1, 2, 3, 4, 5, 6, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.shards.len == expectedConf.numShardsInNetwork.int

  test "Subscribes to some valid shards in twn":
    ## Setup
    let expectedConf = ClusterConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 4, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

    ## When
    let resConf = preConfig.toWakuConf()
    assert resConf.isOk(), $resConf.error

    ## Then
    let conf = resConf.get()
    assert conf.shards.len() == shards.len()
    for index, shard in shards:
      assert shard in conf.shards

  test "Subscribes to invalid shards in twn":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 4, 7, 10]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

    ## When
    let res = preConfig.toWakuConf()

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

  test "Apply TWN preset when cluster id = 1":
    ## Setup
    let expectedConf = ClusterConf.TheWakuNetworkConf()

    ## Given
    let preConfig = WakuNodeConf(
      cmd: noCommand,
      clusterId: 1.uint16,
      relay: true,
      ethClientUrls: @["http://someaddress".EthRpcUrl],
      rlnRelayTreePath: "/tmp/sometreepath",
    )

    ## When
    let res = preConfig.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    check conf.maxMessageSizeBytes ==
      uint64(parseCorrectMsgSize(expectedConf.maxMessageSize))
    check conf.clusterId == expectedConf.clusterId
    check conf.rlnRelayConf.isSome() == expectedConf.rlnRelay
    if conf.rlnRelayConf.isSome():
      let rlnRelayConf = conf.rlnRelayConf.get()
      check rlnRelayConf.ethContractAddress == expectedConf.rlnRelayEthContractAddress
      check rlnRelayConf.dynamic == expectedConf.rlnRelayDynamic
      check rlnRelayConf.chainId == expectedConf.rlnRelayChainId
      check rlnRelayConf.epochSizeSec == expectedConf.rlnEpochSizeSec
      check rlnRelayConf.userMessageLimit == expectedConf.rlnRelayUserMessageLimit
    check conf.numShardsInNetwork == expectedConf.numShardsInNetwork
    check conf.discv5Conf.isSome() == expectedConf.discv5Discovery
    if conf.discv5Conf.isSome():
      let discv5Conf = conf.discv5Conf.get()
      check discv5Conf.bootstrapNodes == expectedConf.discv5BootstrapNodes

suite "Waku config - node key":
  test "Passed node key is used":
    ## Setup
    let nodeKeyStr =
      "0011223344556677889900aabbccddeeff0011223344556677889900aabbccddeeff"
    let nodekey = block:
      let key = SkPrivateKey.init(utils.fromHex(nodeKeyStr)).tryGet()
      crypto.PrivateKey(scheme: Secp256k1, skkey: key)

    ## Given
    let config = WakuNodeConf.load(version = "", cmdLine = @["--nodekey=" & nodeKeyStr])

    ## When
    let res = config.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let resKey = res.get().nodeKey
    assert utils.toHex(resKey.getRawBytes().get()) ==
      utils.toHex(nodekey.getRawBytes().get())

suite "Waku config - Shards":
  test "Shards are valid":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 2, 4]
    let numShardsInNetwork = 5.uint32
    let wakuNodeConf = WakuNodeConf(
      cmd: noCommand, shards: shards, numShardsInNetwork: numShardsInNetwork
    )

    ## When
    let res = wakuNodeConf.toWakuConf()
    assert res.isOk(), $res.error

    ## Then
    let wakuConf = res.get()
    let vRes = wakuConf.validate()
    assert vRes.isOk(), $vRes.error

  test "Shards are not in range":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 2, 5]
    let numShardsInNetwork = 5.uint32
    let wakuNodeConf = WakuNodeConf(
      cmd: noCommand, shards: shards, numShardsInNetwork: numShardsInNetwork
    )

    ## When
    let res = wakuNodeConf.toWakuConf()

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

  test "Shard is passed without num shards":
    ## Setup

    ## Given
    let wakuNodeConf = WakuNodeConf.load(version = "", cmdLine = @["--shard=32"])

    ## When
    let res = wakuNodeConf.toWakuConf()

    ## Then
    let wakuConf = res.get()
    let vRes = wakuConf.validate()
    assert vRes.isOk(), $vRes.error
