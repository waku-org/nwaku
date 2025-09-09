{.used.}

import std/options, results, chronos, testutils/unittests
import library/libwaku_api, library/libwaku_conf, waku/factory/waku

suite "LibWaku - createNode":
  asyncTest "Create node with minimal Relay configuration":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: libwaku_conf.NetworkConf(
        bootstrapNodes: @[],
        staticStoreNodes: @[],
        clusterId: 1,
        shardingMode: StaticSharding,
        autoShardingConf: none(AutoShardingConf),
        messageValidation: none(MessageValidation),
      ),
      storeConfirmation: false,
    )

    ## When
    let node = (await createNode(libConf)).valueOr:
      raiseAssert error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 1
      node.conf.relay == true

  asyncTest "Create node with auto-sharding configuration":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: libwaku_conf.NetworkConf(
        bootstrapNodes: @[],
        staticStoreNodes: @[],
        clusterId: 42,
        shardingMode: AutoSharding,
        autoShardingConf: some(AutoShardingConf(numShardsInCluster: 8)),
        messageValidation: none(MessageValidation),
      ),
      storeConfirmation: false,
    )

    ## When
    let node = (await createNode(libConf)).valueOr:
      raiseAssert error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 42
      node.conf.shardingConf.numShardsInCluster == 8

  asyncTest "Create node with full configuration":
    ## Given
    let libConf = LibWakuConf(
      mode: Relay,
      networkConf: libwaku_conf.NetworkConf(
        bootstrapNodes:
          @[
            "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
          ],
        staticStoreNodes:
          @[
            "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
          ],
        clusterId: 99,
        shardingMode: AutoSharding,
        autoShardingConf: some(AutoShardingConf(numShardsInCluster: 16)),
        messageValidation: some(
          MessageValidation(
            maxMessageSizeBytes: 1024'u64 * 1024'u64, # 1MB
            rlnConfig: none(RlnConfig),
          )
        ),
      ),
      storeConfirmation: true,
    )

    ## When
    let node = (await createNode(libConf)).valueOr:
      raiseAssert error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 99
      node.conf.shardingConf.numShardsInCluster == 16
      node.conf.maxMessageSizeBytes == 1024'u64 * 1024'u64
      node.conf.staticNodes.len == 1
      node.conf.relay == true
      node.conf.lightPush == true
      node.conf.peerExchangeService == true
