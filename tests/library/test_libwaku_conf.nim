{.used.}

import std/options, results, stint, testutils/unittests
import library/libwaku_conf, waku/factory/waku_conf, waku/factory/networks_config

suite "LibWaku Conf - toWakuConf":
  test "Relay mode configuration":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: some(
        libwaku_conf.NetworkConf(
          bootstrapNodes: @[],
          staticStoreNodes: @[],
          clusterId: 1,
          shardingMode: some(ShardingMode.StaticSharding),
          autoShardingConf: none(AutoShardingConf),
          messageValidation: none(MessageValidation),
        )
      ),
      storeConfirmation: false,
    )

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == true
      wakuConf.lightPush == true
      wakuConf.peerExchangeService == true
      wakuConf.clusterId == 1
      wakuConf.shardingConf.kind == ShardingConfKind.StaticSharding

  test "Auto-sharding configuration":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: some(
        libwaku_conf.NetworkConf(
          bootstrapNodes: @[],
          staticStoreNodes: @[],
          clusterId: 42,
          shardingMode: some(ShardingMode.AutoSharding),
          autoShardingConf: some(AutoShardingConf(numShardsInCluster: 16)),
          messageValidation: none(MessageValidation),
        )
      ),
      storeConfirmation: false,
    )

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 42
      wakuConf.shardingConf.kind == ShardingConfKind.AutoSharding
      wakuConf.shardingConf.numShardsInCluster == 16

  test "Bootstrap nodes configuration":
    ## Given
    let bootstrapNodes =
      @[
        "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g",
        "enr:-QEkuECnZ3IbVAgkOzv-QLnKC4dRKAPRY80m1-R7G8jZ7yfT3ipEfBrhKN7ARcQgQ-vg-h40AQzyvAkPYlHPaFKk6u9MBgmlkgnY0iXNlY3AyNTZrMaEDk49D8JjMSns4p1XVNBvJquOUzT4PENSJknkROspfAFGg3RjcIJ2X4N1ZHCCd2g",
      ]
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: some(
        libwaku_conf.NetworkConf(
          bootstrapNodes: bootstrapNodes,
          staticStoreNodes: @[],
          clusterId: 1,
          shardingMode: some(ShardingMode.StaticSharding),
          autoShardingConf: none(AutoShardingConf),
          messageValidation: none(MessageValidation),
        )
      ),
      storeConfirmation: false,
    )

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    require wakuConf.discv5Conf.isSome()
    check:
      wakuConf.discv5Conf.get().bootstrapNodes == bootstrapNodes

  test "Static store nodes configuration":
    ## Given
    let staticStoreNodes =
      @[
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
        "/ip4/192.168.1.1/tcp/60001/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYd",
      ]
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: some(
        libwaku_conf.NetworkConf(
          bootstrapNodes: @[],
          staticStoreNodes: staticStoreNodes,
          clusterId: 1,
          shardingMode: some(ShardingMode.StaticSharding),
          autoShardingConf: none(AutoShardingConf),
          messageValidation: none(MessageValidation),
        )
      ),
      storeConfirmation: false,
    )

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.staticNodes == staticStoreNodes

  test "Message validation with max message size":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: some(
        libwaku_conf.NetworkConf(
          bootstrapNodes: @[],
          staticStoreNodes: @[],
          clusterId: 1,
          shardingMode: some(ShardingMode.StaticSharding),
          autoShardingConf: none(AutoShardingConf),
          messageValidation: some(
            MessageValidation(
              maxMessageSizeBytes: 100'u64 * 1024'u64, # 100kB
              rlnConfig: none(RlnConfig),
            )
          ),
        )
      ),
      storeConfirmation: false,
    )

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.maxMessageSizeBytes == 100'u64 * 1024'u64

  test "Message validation with RLN config":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: some(
        libwaku_conf.NetworkConf(
          bootstrapNodes: @[],
          staticStoreNodes: @[],
          clusterId: 1,
          shardingMode: some(ShardingMode.StaticSharding),
          autoShardingConf: none(AutoShardingConf),
          messageValidation: some(
            MessageValidation(
              maxMessageSizeBytes: 150'u64 * 1024'u64, # 150KB
              rlnConfig: some(
                RlnConfig(
                  contractAddress: "0x1234567890123456789012345678901234567890",
                  chainId: 1'u,
                  epochSizeSec: 600'u64,
                )
              ),
            )
          ),
        )
      ),
      storeConfirmation: false,
      ethRpcEndpoints: @["http://127.0.0.1:1111"],
    )

    ## When
    let wakuConf = toWakuConf(libConf).valueOr:
      raiseAssert error

    wakuConf.validate().isOkOr:
      raiseAssert error

    check:
      wakuConf.maxMessageSizeBytes == 150'u64 * 1024'u64

    require wakuConf.rlnRelayConf.isSome()
    let rlnConf = wakuConf.rlnRelayConf.get()
    check:
      rlnConf.dynamic == true
      rlnConf.ethContractAddress == "0x1234567890123456789012345678901234567890"
      rlnConf.chainId == 1'u256
      rlnConf.epochSizeSec == 600'u64

  test "Full Relay mode configuration with all fields":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: some(
        libwaku_conf.NetworkConf(
          bootstrapNodes:
            @[
              "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
            ],
          staticStoreNodes:
            @[
              "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
            ],
          clusterId: 99,
          shardingMode: some(ShardingMode.AutoSharding),
          autoShardingConf: some(AutoShardingConf(numShardsInCluster: 8)),
          messageValidation: some(
            MessageValidation(
              maxMessageSizeBytes: 512'u64 * 1024'u64, # 512KB
              rlnConfig: some(
                RlnConfig(
                  contractAddress: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                  chainId: 5'u, # Goerli
                  epochSizeSec: 300'u64,
                )
              ),
            )
          ),
        )
      ),
      storeConfirmation: true,
      ethRpcEndpoints: @["https://127.0.0.1:8333"],
    )

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    let wakuConf = wakuConfRes.valueOr:
      raiseAssert error
    wakuConf.validate().isOkOr:
      raiseAssert error

    # Check basic settings
    check:
      wakuConf.relay == true
      wakuConf.lightPush == true
      wakuConf.peerExchangeService == true
      wakuConf.clusterId == 99

    # Check sharding
    check:
      wakuConf.shardingConf.kind == ShardingConfKind.AutoSharding
      wakuConf.shardingConf.numShardsInCluster == 8

    # Check bootstrap nodes
    require wakuConf.discv5Conf.isSome()
    check:
      wakuConf.discv5Conf.get().bootstrapNodes.len == 1

    # Check static nodes
    check:
      wakuConf.staticNodes.len == 1
      wakuConf.staticNodes[0] ==
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    # Check message validation
    check:
      wakuConf.maxMessageSizeBytes == 512'u64 * 1024'u64

    # Check RLN config
    require wakuConf.rlnRelayConf.isSome()
    let rlnConf = wakuConf.rlnRelayConf.get()
    check:
      rlnConf.dynamic == true
      rlnConf.ethContractAddress == "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      rlnConf.chainId == 5'u256
      rlnConf.epochSizeSec == 300'u64

  test "Minimal configuration":
    ## Given
    let libConf = LibWakuConf(mode: Relay, ethRpcEndpoints: @["http://someaddress"])

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    let wakuConf = wakuConfRes.valueOr:
      raiseAssert error
    wakuConf.validate().isOkOr:
      raiseAssert error
    check:
      wakuConf.clusterId == 1
      wakuConf.shardingConf.kind == ShardingConfKind.AutoSharding
      wakuConf.shardingConf.numShardsInCluster == 8
      wakuConf.staticNodes.len == 0
