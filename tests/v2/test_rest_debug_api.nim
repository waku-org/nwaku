{.used.}

import
  stew/shims/net,
  chronicles,
  testutils/unittests,
  presto, 
  libp2p/crypto/crypto
import
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/rest/[server, client, utils],
  ../../waku/v2/node/rest/debug/debug_api


proc testWakuNode(): WakuNode = 
  let 
    rng = crypto.newRng()
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(9000)

  WakuNode.new(privkey, bindIp, port, some(extIp), some(port))


suite "REST API - Debug":
  asyncTest "Get node info - GET /debug/v1/info": 
    # Given
    let node = testWakuNode()
    await node.start()
    node.mountRelay()

    let restPort = Port(8546)
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
      response.contentType == $MIMETYPE_JSON
      response.data.listenAddresses == @[$node.switch.peerInfo.addrs[^1] & "/p2p/" & $node.switch.peerInfo.peerId]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()