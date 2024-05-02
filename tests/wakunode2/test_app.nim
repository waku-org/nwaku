{.used.}

import
  stew/shims/net,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/switch
import ../testlib/common, ../testlib/wakucore, ../testlib/wakunode

include ../../waku/factory/waku

suite "Wakunode2 - Waku":
  test "compilation version should be reported":
    ## Given
    let conf = defaultTestWakuNodeConf()

    let wakunode2 = Waku.init(conf).valueOr:
      raiseAssert error

    ## When
    let version = wakunode2.version

    ## Then
    check:
      version == git_version

suite "Wakunode2 - Waku initialization":
  test "peer persistence setup should be successfully mounted":
    ## Given
    var conf = defaultTestWakuNodeConf()
    conf.peerPersistence = true

    let wakunode2 = Waku.init(conf).valueOr:
      raiseAssert error

    check:
      not wakunode2.node.peerManager.storage.isNil()

  test "node setup is successful with default configuration":
    ## Given
    let conf = defaultTestWakuNodeConf()

    ## When
    var wakunode2 = Waku.init(conf).valueOr:
      raiseAssert error

    (waitFor wakunode2.startWaku()).isOkOr:
      raiseAssert error

    wakunode2.metricsServer = waku_metrics.startMetricsServerAndLogging(conf).valueOr:
      raiseAssert error

    ## Then
    let node = wakunode2.node
    check:
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      not node.wakuStoreClient.isNil()
      not node.rendezvous.isNil()

    ## Cleanup
    waitFor wakunode2.stop()

  test "app properly handles dynamic port configuration":
    ## Given
    var conf = defaultTestWakuNodeConf()
    conf.tcpPort = Port(0)

    ## When
    var wakunode2 = Waku.init(conf).valueOr:
      raiseAssert error

    (waitFor wakunode2.startWaku()).isOkOr:
      raiseAssert error

    ## Then
    let
      node = wakunode2.node
      typedNodeEnr = node.enr.toTypedRecord()

    assert typedNodeEnr.isOk(), $typedNodeEnr.error

    check:
      # Waku started properly
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      not node.wakuStoreClient.isNil()
      not node.rendezvous.isNil()

      # DS structures are updated with dynamic ports
      typedNodeEnr.get().tcp.get() != 0

    ## Cleanup
    waitFor wakunode2.stop()
