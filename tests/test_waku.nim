{.used.}

import results

import chronos, testutils/unittests

import logos_delivery
import ./testlib/wakunodeconf

suite "LogosDelivery API - Create node":
  asyncTest "Create node with minimal configuration":
    ## Given
    let nodeConf = defaultTestWakuNodeConf()

    # This is the actual minimal config but as the node auto-start, it is not suitable for tests

    ## When
    let ld = (
      await LogosDelivery.new(
        KernelConf(nodeConf), MessagingClientConf(), ReliableChannelManagerConf()
      )
    ).valueOr:
      raiseAssert "LogosDelivery.new (minimal config) failed: " & error

    ## Then
    check:
      not ld.isNil()
      ld.kernel.conf.clusterId == 3
      ld.kernel.conf.relay == true

  asyncTest "Create node with full configuration":
    ## Given
    var nodeConf = defaultTestWakuNodeConf()
    nodeConf.clusterId = Opt.some(99'u16)
    nodeConf.numShardsInNetwork = 16
    nodeConf.maxMessageSize = "1024 KiB"
    nodeConf.entryNodes = @[
      "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
    ]
    nodeConf.staticnodes = @[
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
    ]

    ## When
    let ld = (
      await LogosDelivery.new(
        KernelConf(nodeConf), MessagingClientConf(), ReliableChannelManagerConf()
      )
    ).valueOr:
      raiseAssert "LogosDelivery.new (full config) failed: " & error

    ## Then
    check:
      not ld.isNil()
      ld.kernel.conf.clusterId == 99
      ld.kernel.conf.shardingConf.shards.len == 16
      ld.kernel.conf.maxMessageSizeBytes == 1024'u64 * 1024'u64
      ld.kernel.conf.staticNodes.len == 1
      ld.kernel.conf.relay == true
      ld.kernel.conf.lightPush == true
      ld.kernel.conf.peerExchangeService == true
      ld.kernel.conf.rendezvous == true

  asyncTest "Create node with mixed entry nodes (enrtree, multiaddr)":
    ## Given
    var nodeConf = defaultTestWakuNodeConf()
    nodeConf.clusterId = Opt.some(42'u16)
    nodeConf.entryNodes = @[
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
    ]

    ## When
    let ld = (
      await LogosDelivery.new(
        KernelConf(nodeConf), MessagingClientConf(), ReliableChannelManagerConf()
      )
    ).valueOr:
      raiseAssert "LogosDelivery.new (mixed entry nodes) failed: " & error

    ## Then
    check:
      not ld.isNil()
      ld.kernel.conf.clusterId == 42
      # ENRTree should go to DNS discovery
      ld.kernel.conf.dnsDiscoveryConf.isSome()
      ld.kernel.conf.dnsDiscoveryConf.get().enrTreeUrl ==
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      # Multiaddr should go to static nodes
      ld.kernel.conf.staticNodes.len == 1
      ld.kernel.conf.staticNodes[0] ==
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
