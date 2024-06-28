{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  libp2p/crypto/[crypto, secp],
  libp2p/multiaddress,
  nimcrypto/utils,
  secp256k1
import
  ../../waku/factory/external_config,
  ../../waku/factory/internal_config,
  ../../waku/factory/networks_config

suite "Waku config - apply preset":
  test "Default preset is TWN":
    ## Setup
    let twnConf = ClusterConf.TheWakuNetworkConf()

    ## Given
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "default")

    ## When
    let res = applyPresetConfiguration(preConfig)
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.maxMessageSize == twnConf.maxMessageSize
    assert conf.clusterId == twnConf.clusterId
    assert conf.rlnRelay == twnConf.rlnRelay
    assert conf.rlnRelayEthContractAddress == twnConf.rlnRelayEthContractAddress
    assert conf.rlnRelayChainId == twnConf.rlnRelayChainId
    assert conf.rlnRelayDynamic == twnConf.rlnRelayDynamic
    assert conf.rlnRelayBandwidthThreshold == twnConf.rlnRelayBandwidthThreshold
    assert conf.rlnEpochSizeSec == twnConf.rlnEpochSizeSec
    assert conf.rlnRelayUserMessageLimit == twnConf.rlnRelayUserMessageLimit
    assert conf.pubsubTopics == twnConf.pubsubTopics
    assert conf.discv5Discovery == twnConf.discv5Discovery
    assert conf.discv5BootstrapNodes == twnConf.discv5BootstrapNodes

  test "Subscribes to all valid shards in default network":
    ## Setup
    let twnConf = ClusterConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 1, 2, 3, 4, 5, 6, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "default", shards: shards)

    ## When
    let res = applyPresetConfiguration(preConfig)
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.pubsubTopics == twnConf.pubsubTopics

  test "Subscribes to some valid shards in default network":
    ## Setup
    let twnConf = ClusterConf.TheWakuNetworkConf()

    ## Given
    let shards: seq[uint16] = @[0, 4, 7]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "default", shards: shards)

    ## When
    let res = applyPresetConfiguration(preConfig)
    assert res.isOk(), $res.error

    ## Then
    let conf = res.get()
    assert conf.pubsubTopics.len() == shards.len()
    assert twnConf.pubsubTopics[0] in conf.pubsubTopics
    assert twnConf.pubsubTopics[4] in conf.pubsubTopics
    assert twnConf.pubsubTopics[7] in conf.pubsubTopics

  test "Subscribes to invalid shards in default network":
    ## Setup

    ## Given
    let shards: seq[uint16] = @[0, 4, 7, 10]
    let preConfig = WakuNodeConf(cmd: noCommand, preset: "default", shards: shards)

    ## When
    let res = applyPresetConfiguration(preConfig)

    ## Then
    assert res.isErr(), "Invalid shard was accepted"

suite "Waku config - node key":
  test "Passed node key is used":
    ## Setup
    let nodekey = block:
      let key = SkPrivateKey
        .init(
          utils.fromHex(
            "0011223344556677889900aabbccddeeff0011223344556677889900aabbccddeeff"
          )
        )
        .tryGet()
      crypto.PrivateKey(scheme: Secp256k1, skkey: key)

    ## Given
    let preConfig = WakuNodeConf(cmd: noCommand, nodekey: some(nodekey))

    ## When
    let res = nodeKeyConfiguration(preConfig)
    assert res.isOk(), $res.error

    ## Then
    let resKey = res.get()
    assert utils.toHex(resKey.getRawBytes().get()) ==
      utils.toHex(nodekey.getRawBytes().get())
