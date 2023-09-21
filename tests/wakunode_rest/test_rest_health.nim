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
  ../../waku/node/waku_node as waku_node2,  # TODO: Remove after moving `git_version` to the app code.
  ../../waku/node/rest/server,
  ../../waku/node/rest/client,
  ../../waku/node/rest/responses,
  ../../waku/node/rest/health/handlers as health_api,
  ../../waku/node/rest/health/client as health_api_client,
  ../../waku/waku_rln_relay,
  ../testlib/common,
  ../testlib/testutils,
  ../testlib/wakucore,
  ../testlib/wakunode


proc testWakuNode(): WakuNode =
  let
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))


suite "Waku v2 REST API - health":
  # TODO: better test for health
  xasyncTest "Get node health info - GET /health":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58001)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installHealthApiHandler(restServer.router, node)
    restServer.start()
    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    # When
    var response = await client.healthCheck()

    # Then
    check:
      response.status == 503
      $response.contentType == $MIMETYPE_TEXT
      response.data == "Node is not ready"

    # now kick in rln (currently the only check for health)
    await node.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: some(1.uint),
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode"),
    ))

    # When
    response = await client.healthCheck()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "Node is healthy"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
