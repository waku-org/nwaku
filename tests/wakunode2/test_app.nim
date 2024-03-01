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
  ../testlib/wakunode

include
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
      version == git_version

suite "Wakunode2 - App initialization":
  test "peer persistence setup should be successfully mounted":
    ## Given
    var conf = defaultTestWakuNodeConf()
    conf.peerPersistence = true

    var wakunode2 = App.init(rng(), conf)

    ## When
    let res = wakunode2.setupPeerPersistence()

    ## Then
    assert res.isOk(), $res.error

  test "node setup is successful with default configuration":
    ## Given
    let conf = defaultTestWakuNodeConf()

    ## When
    var wakunode2 = App.init(rng(), conf)

    let persRes = wakunode2.setupPeerPersistence()
    assert persRes.isOk(), persRes.error

    let bootRes = wakunode2.setupDyamicBootstrapNodes()
    assert bootRes.isOk(), bootRes.error

    let setupRes = wakunode2.setupWakuApp()
    assert setupRes.isOk(), setupRes.error

    let mountRes = waitFor wakunode2.setupAndMountProtocols()
    assert mountRes.isOk(), mountRes.error

    let startRes = wakunode2.startApp()
    assert startRes.isOk(), startRes.error

    let monitorRes = wakunode2.setupMonitoringAndExternalInterfaces()
    assert monitorRes.isOk(), monitorRes.error

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
    var wakunode2 = App.init(rng(), conf)
    require wakunode2.setupPeerPersistence().isOk()
    require wakunode2.setupDyamicBootstrapNodes().isOk()
    require wakunode2.setupWakuApp().isOk()
    require isOk(waitFor wakunode2.setupAndMountProtocols())
    require isOk(wakunode2.startApp())
    require wakunode2.setupMonitoringAndExternalInterfaces().isOk()

    ## Then
    let 
      node = wakunode2.node
      typedNodeEnr = node.enr.toTypedRecord()
      typedAppEnr = wakunode2.record.toTypedRecord()

    assert typedNodeEnr.isOk(), $typedNodeEnr.error
    assert typedAppEnr.isOk(), $typedAppEnr.error

    check:
      # App started properly
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      not node.wakuStoreClient.isNil()
      not node.rendezvous.isNil()

      # DS structures are updated with dynamic ports
      wakunode2.netConf.bindPort != Port(0)
      wakunode2.netConf.enrPort.get() != Port(0)
      typedNodeEnr.get().tcp.get() != 0
      typedAppEnr.get().tcp.get() != 0

    ## Cleanup
    waitFor wakunode2.stop()
