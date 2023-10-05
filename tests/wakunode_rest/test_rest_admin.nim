{.used.}

import
  std/sequtils,
  stew/shims/net,
  testutils/unittests,
  presto, presto/client as presto_client,
  libp2p/crypto/crypto

import
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/node/peer_manager,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/client,
  ../../waku/waku_api/rest/responses,
  ../../waku/waku_api/rest/admin/types,
  ../../waku/waku_api/rest/admin/handlers as admin_api,
  ../../waku/waku_api/rest/admin/client as admin_api_client,
  ../../waku/waku_relay,
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/testasync

suite "Waku v2 Rest API - Admin":
  var node1 {.threadvar.}: WakuNode
  var node2 {.threadvar.}: WakuNode
  var node3 {.threadvar.}: WakuNode
  var peerInfo2 {.threadvar.}: RemotePeerInfo
  var peerInfo3 {.threadvar.}: RemotePeerInfo
  var restServer {.threadvar.}: RestServerRef
  var client{.threadvar.}: RestClientRef

  asyncSetup:
    node1 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(60600))
    node2 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(60602))
    peerInfo2 = node2.switch.peerInfo
    node3 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(60604))
    peerInfo3 = node3.switch.peerInfo

    await allFutures(node1.start(), node2.start(), node3.start())
    await allFutures(node1.mountRelay(), node2.mountRelay(), node3.mountRelay())

    let restPort = Port(58011)
    let restAddress = ValidIpAddress.init("127.0.0.1")
    restServer = RestServerRef.init(restAddress, restPort).tryGet()

    installAdminApiHandlers(restServer.router, node1)

    restServer.start()

    client = newRestHttpClient(initTAddress(restAddress, restPort))

  asyncTearDown:
    await restServer.stop()
    await restServer.closeWait()
    await allFutures(node1.stop(), node2.stop(), node3.stop())

  asyncTest "Set and get remote peers":
    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.postPeers(@[constructMultiaddrStr(peerInfo2),
                                           constructMultiaddrStr(peerInfo3)])

    check:
      postRes.status == 200

    # Verify that newly connected peers are being managed
    let getRes = await client.getPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      # Check peer 2
      getRes.data.anyIt(it.protocols.find(WakuRelayCodec) >= 0 and
                   it.multiaddr == constructMultiaddrStr(peerInfo2))
      # Check peer 3
      getRes.data.anyIt(it.protocols.find(WakuRelayCodec) >= 0 and
                   it.multiaddr == constructMultiaddrStr(peerInfo3))

  asyncTest "Set wrong peer":
    let nonExistentPeer = "/ip4/0.0.0.0/tcp/10000/p2p/16Uiu2HAm6HZZr7aToTvEBPpiys4UxajCTU97zj5v7RNR2gbniy1D"
    let postRes = await client.postPeers(@[nonExistentPeer])

    check:
      postRes.status == 400
      $postRes.contentType == $MIMETYPE_TEXT
      postRes.data == "Failed to connect to peer at index: 0 - " & nonExistentPeer

    # Verify that newly connected peers are being managed
    let getRes = await client.getPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 0
