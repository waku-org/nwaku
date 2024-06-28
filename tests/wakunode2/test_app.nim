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
import
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode,
  node/waku_metrics

include factory/waku

suite "Wakunode2 - Waku":
  test "compilation version should be reported":
    ## Given
    let conf = defaultTestWakuNodeConf()

    let waku = Waku.init(conf).valueOr:
      raiseAssert error

    ## When
    let version = waku.version

    ## Then
    check:
      version == git_version

suite "Wakunode2 - Waku initialization":
  test "peer persistence setup should be successfully mounted":
    ## Given
    var conf = defaultTestWakuNodeConf()
    conf.peerPersistence = true

    let waku = Waku.init(conf).valueOr:
      raiseAssert error

    check:
      not waku.node.peerManager.storage.isNil()

  test "node setup is successful with default configuration":
    ## Given
    let conf = defaultTestWakuNodeConf()

    ## When
    var waku = Waku.init(conf).valueOr:
      raiseAssert error

    (waitFor startWaku(addr waku)).isOkOr:
      raiseAssert error

    waku.metricsServer = waku_metrics.startMetricsServerAndLogging(conf).valueOr:
      raiseAssert error

    ## Then
    let node = waku.node
    check:
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      not node.wakuStoreClient.isNil()
      not node.rendezvous.isNil()

    ## Cleanup
    waitFor waku.stop()

  test "app properly handles dynamic port configuration":
    ## Given
    var conf = defaultTestWakuNodeConf()
    conf.tcpPort = Port(0)

    ## When
    var waku = Waku.init(conf).valueOr:
      raiseAssert error

    (waitFor startWaku(addr waku)).isOkOr:
      raiseAssert error

    ## Then
    let
      node = waku.node
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
    waitFor waku.stop()
