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
  ../../apps/wakunode2/config,
  ../../apps/wakunode2/app,
  ../v2/testlib/common,
  ../v2/testlib/wakucore


proc dummyTestWakuNodeConf(): WakuNodeConf =
  WakuNodeConf(
    listenAddress: ValidIpAddress.init("127.0.0.1"),
    rpcAddress: ValidIpAddress.init("127.0.0.1"),
    restAddress: ValidIpAddress.init("127.0.0.1"),
    metricsServerAddress: ValidIpAddress.init("127.0.0.1"),
  )


suite "Wakunode2 - App":
  test "compilation version should be reported":
    ## Given
    let conf = dummyTestWakuNodeConf()

    var wakunode2 = App.init(rng(), conf)

    ## When
    let version = wakunode2.version

    ## Then
    check:
      version == app.git_version


suite "Wakunode2 - App initialization":
  test "peer persistence setup should be successfully mounted":
    ## Given
    var conf = dummyTestWakuNodeConf()
    conf.peerPersistence = true

    var wakunode2 = App.init(rng(), conf)

    ## When
    let res = wakunode2.setupPeerPersistence()

    ## Then
    check res.isOk()
