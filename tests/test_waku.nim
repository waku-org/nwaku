{.used.}

import chronos, testutils/unittests, std/options

import waku

suite "Waku API - Create node":
  asyncTest "Create node with minimal Relay configuration":
    ## Given
    let nodeConfig =
      newNodeConfig(wakuConfig = newWakuConfig(seedNodes = @[], clusterId = 1))

    ## When
    let node = (await createNode(nodeConfig)).valueOr:
      raiseAssert error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 1
      node.conf.relay == true

  asyncTest "Create node with full configuration":
    ## Given
    let nodeConfig = newNodeConfig(
      mode = Relay,
      wakuConfig = newWakuConfig(
        seedNodes =
          @[
            "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
          ],
        staticStoreNodes =
          @[
            "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
          ],
        clusterId = 99,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 16),
        messageValidation =
          MessageValidation(maxMessageSize: "1024 KiB", rlnConfig: none(RlnConfig)),
      ),
      messageConfirmation = @[MessageConfirmationMode.Store],
    )

    ## When
    let node = (await createNode(nodeConfig)).valueOr:
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
