{.used.}

import
  stew/shims/net,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/peerinfo,
  libp2p/multiaddress,
  libp2p/crypto/crypto
import
  ../../waku/v2/node/waku_node,
  ../../waku/v2/node/rest/server,
  ../../waku/v2/node/rest/client,
  ../../waku/v2/node/rest/responses,
  ../../waku/v2/node/rest/debug/handlers as debug_api,
  ../../waku/v2/node/rest/debug/client as debug_api_client


proc testWakuNode(): WakuNode =
  let
    rng = crypto.newRng()
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(58000)

  WakuNode.new(privkey, bindIp, port, some(extIp), some(port))


suite "Waku v2 REST API - Debug":
  asyncTest "Get node info - GET /debug/v1/info":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58001)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.debugInfoV1()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.listenAddresses == @[$node.switch.peerInfo.addrs[^1] & "/p2p/" & $node.switch.peerInfo.peerId]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Get node version - GET /debug/v1/version":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58002)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.debugVersionV1()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == waku_node.git_version

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
