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
  ../../apps/wakunode2/app

suite "Wakunode2 - App":
  test "compilation version should be reported":
    ## Given
    let conf = defaultTestWakuNodeConf()

    var wakunode2 = App.init(rng(), conf)

    ## When
    let version = wakunode2.version

    ## Then
    check:
      version == app.git_version

suite "Wakunode2 - App initialization":
  test "peer persistence setup should be successfully mounted":
    ## Given
    var conf = defaultTestWakuNodeConf()
    conf.peerPersistence = true

    var wakunode2 = App.init(rng(), conf)

    ## When
    let res = wakunode2.setupPeerPersistence()

    ## Then
    check res.isOk()

  test "node setup is successful with default configuration":
    ## Given
    let conf = defaultTestWakuNodeConf()

    ## When
    var wakunode2 = App.init(rng(), conf)
    require wakunode2.setupPeerPersistence().isOk()
    require wakunode2.setupDyamicBootstrapNodes().isOk()
    require wakunode2.setupWakuApp().isOk()
    require isOk(waitFor wakunode2.setupAndMountProtocols())
    require isOk(waitFor wakunode2.startApp())
    require wakunode2.setupMonitoringAndExternalInterfaces().isOk()

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
