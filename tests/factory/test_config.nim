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
  ../../waku/factory/internal_config,
  ../../waku/factory/networks_config,
  ../../waku/common/logging

suite "Waku config - apply preset":
  test "Default preset is TWN":
    ## Setup
    let expectedConf = NetworkConfig.TheWakuNetworkConf()

    ## Given
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn")

    ## When
    let res = applyPresetConfiguration(preConfig)
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.maxMessageSize == expectedConf.maxMessageSize
    assert conf.clusterId == expectedConf.clusterId
    assert conf.rlnRelay == expectedConf.rlnRelay
    assert conf.rlnRelayEthContractAddress == expectedConf.rlnRelayEthContractAddress
    assert conf.rlnRelayDynamic == expectedConf.rlnRelayDynamic
    assert conf.rlnRelayChainId == expectedConf.rlnRelayChainId
    assert conf.rlnRelayBandwidthThreshold == expectedConf.rlnRelayBandwidthThreshold
    assert conf.rlnEpochSizeSec == expectedConf.rlnEpochSizeSec
    assert conf.rlnRelayUserMessageLimit == expectedConf.rlnRelayUserMessageLimit
    assert conf.numShardsInNetwork == expectedConf.numShardsInNetwork
    assert conf.discv5BootstrapNodes == expectedConf.discv5BootstrapNodes

  test "Subscribes to all valid shards in twn":
    ## Setup
    let expectedConf = NetworkConfig.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 1, 2, 3, 4, 5, 6, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

    ## When
    let res = applyPresetConfiguration(preConfig)
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.shards.len == expectedConf.numShardsInNetwork.int

  test "Subscribes to some valid shards in twn":
    ## Setup
    let expectedConf = NetworkConfig.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 4, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "twn", shards: shards)

    ## When
    let resConf = applyPresetConfiguration(preConfig)
    let res = validateShards(resConf.get())
    assert res.isOk(), $res.error

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
    let postConfig = applyPresetConfiguration(preConfig)

    ## When
    let res = validateShards(postConfig.get())

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

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
    let res = getNodeKey(config)
    assert res.isOk(), $res.error

    ## Then
    let resKey = res.get()
    assert utils.toHex(resKey.getRawBytes().get()) ==
      utils.toHex(nodekey.getRawBytes().get())

suite "Waku config - Shards":
  test "Shards are valid":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 2, 4]
    let numShardsInNetwork = 5.uint32
    let config = WakuNodeConf(
      cmd: noCommand, shards: shards, numShardsInNetwork: numShardsInNetwork
    )

    ## When
    let res = validateShards(config)

    ## Then
    assert res.isOk(), $res.error

  test "Shards are not in range":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 2, 5]
    let numShardsInNetwork = 5.uint32
    let config = WakuNodeConf(
      cmd: noCommand, shards: shards, numShardsInNetwork: numShardsInNetwork
    )

    ## When
    let res = validateShards(config)

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

  test "Shard is passed without num shards":
    ## Setup

    ## Given
    let config = WakuNodeConf.load(version = "", cmdLine = @["--shard=32"])

    ## When
    let res = validateShards(config)

    ## Then
    assert res.isOk(), $res.error
