{.used.}

import
  std/tempfiles,
  stew/shims/net,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/peerinfo,
  libp2p/multiaddress,
  libp2p/crypto/crypto
import
  ../../waku/waku_node,
  ../../waku/node/waku_node as waku_node2,
    # TODO: Remove after moving `git_version` to the app code.
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/client,
  ../../waku/waku_api/rest/responses,
  ../../waku/waku_api/rest/health/handlers as health_api,
  ../../waku/waku_api/rest/health/client as health_api_client,
  ../../waku/waku_rln_relay,
  ../../waku/node/health_monitor,
  ../testlib/common,
  ../testlib/testutils,
  ../testlib/wakucore,
  ../testlib/wakunode

proc testWakuNode(): WakuNode =
  let
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

suite "Waku v2 REST API - health":
  # TODO: better test for health
  asyncTest "Get node health info - GET /health":
    # Given
    let node = testWakuNode()
    let healthMonitor = WakuNodeHealthMonitor()
    await node.start()
    await node.mountRelay()

    healthMonitor.setOverallHealth(HealthStatus.INITIALIZING)

    let restPort = Port(58001)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    installHealthApiHandler(restServer.router, healthMonitor)
    restServer.start()
    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    # When
    var response = await client.healthCheck()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data ==
        HealthReport(nodeHealth: HealthStatus.INITIALIZING, protocolsHealth: @[])

    # now kick in rln (currently the only check for health)
    await node.mountRlnRelay(
      WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode"),
      )
    )
    healthMonitor.setNode(node)
    healthMonitor.setOverallHealth(HealthStatus.READY)
    # When
    response = await client.healthCheck()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.nodeHealth == HealthStatus.READY
      response.data.protocolsHealth.len() == 1
      response.data.protocolsHealth[0].protocol == "Rln Relay"
      response.data.protocolsHealth[0].health == HealthStatus.READY

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
