{.used.}

import
  std/[sequtils, strformat],
  stew/shims/net,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto

import
  waku/[
    waku_core,
    waku_node,
    waku_filter_v2/client,
    node/peer_manager,
    waku_api/rest/server,
    waku_api/rest/client,
    waku_api/rest/responses,
    waku_api/rest/admin/types,
    waku_api/rest/admin/handlers as admin_api,
    waku_api/rest/admin/client as admin_api_client,
    waku_relay,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/testasync

suite "Waku v2 Rest API - Admin":
  var node1 {.threadvar.}: WakuNode
  var node2 {.threadvar.}: WakuNode
  var node3 {.threadvar.}: WakuNode
  var peerInfo1 {.threadvar.}: RemotePeerInfo
  var peerInfo2 {.threadvar.}: RemotePeerInfo
  var peerInfo3 {.threadvar.}: RemotePeerInfo
  var restServer {.threadvar.}: WakuRestServerRef
  var client {.threadvar.}: RestClientRef

  asyncSetup:
    node1 =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(60600))
    node2 =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(60602))
    node3 =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(60604))

    await allFutures(node1.start(), node2.start(), node3.start())
    await allFutures(node1.mountRelay(), node2.mountRelay(), node3.mountRelay())

    peerInfo1 = node1.switch.peerInfo
    peerInfo2 = node2.switch.peerInfo
    peerInfo3 = node3.switch.peerInfo

    var restPort = Port(0)
    let restAddress = parseIpAddress("127.0.0.1")
    restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installAdminApiHandlers(restServer.router, node1)

    restServer.start()

    client = newRestHttpClient(initTAddress(restAddress, restPort))

  asyncTearDown:
    await restServer.stop()
    await restServer.closeWait()
    await allFutures(node1.stop(), node2.stop(), node3.stop())

  asyncTest "Set and get remote peers":
    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.postPeers(
      @[constructMultiaddrStr(peerInfo2), constructMultiaddrStr(peerInfo3)]
    )

    check:
      postRes.status == 200

    # Verify that newly connected peers are being managed
    let getRes = await client.getPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      # Check peer 2
      getRes.data.anyIt(
        it.protocols.find(WakuRelayCodec) >= 0 and
          it.multiaddr == constructMultiaddrStr(peerInfo2)
      )
      # Check peer 3
      getRes.data.anyIt(
        it.protocols.find(WakuRelayCodec) >= 0 and
          it.multiaddr == constructMultiaddrStr(peerInfo3)
      )

  asyncTest "Set wrong peer":
    let nonExistentPeer =
      "/ip4/0.0.0.0/tcp/10000/p2p/16Uiu2HAm6HZZr7aToTvEBPpiys4UxajCTU97zj5v7RNR2gbniy1D"
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

  asyncTest "Get filter data":
    await allFutures(
      node1.mountFilter(), node2.mountFilterClient(), node3.mountFilterClient()
    )

    let
      contentFiltersNode2 = @[DefaultContentTopic, ContentTopic("2"), ContentTopic("3")]
      contentFiltersNode3 = @[ContentTopic("3"), ContentTopic("4")]
      pubsubTopicNode2 = DefaultPubsubTopic
      pubsubTopicNode3 = PubsubTopic("/waku/2/custom-waku/proto")

    let
      subscribeResponse2 = await node2.wakuFilterClient.subscribe(
        peerInfo1, pubsubTopicNode2, contentFiltersNode2
      )
      subscribeResponse3 = await node3.wakuFilterClient.subscribe(
        peerInfo1, pubsubTopicNode3, contentFiltersNode3
      )

    assert subscribeResponse2.isOk(), $subscribeResponse2.error
    assert subscribeResponse3.isOk(), $subscribeResponse3.error

    let getRes = await client.getFilterSubscriptions()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2

    let
      peers = @[getRes.data[0].peerId, getRes.data[1].peerId]
      numCriteria =
        @[getRes.data[0].filterCriteria.len, getRes.data[1].filterCriteria.len]

    check:
      $peerInfo2 in peers
      $peerInfo3 in peers
      2 in numCriteria
      3 in numCriteria

  asyncTest "Get filter data - no filter subscribers":
    await node1.mountFilter()

    let getRes = await client.getFilterSubscriptions()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 0

  asyncTest "Get filter data - filter not mounted":
    let getRes = await client.getFilterSubscriptionsFilterNotMounted()

    check:
      getRes.status == 400
      getRes.data == "Error: Filter Protocol is not mounted to the node"

  asyncTest "Get peer origin":
    # Adding peers to the Peer Store  
    node1.peerManager.addPeer(peerInfo2, Discv5)
    node1.peerManager.addPeer(peerInfo3, PeerExchange)

    # Connecting to both peers
    let conn2 = await node1.peerManager.connectRelay(peerInfo2)
    let conn3 = await node1.peerManager.connectRelay(peerInfo3)

    # Check successful connections
    check:
      conn2 == true
      conn3 == true

    # Query peers REST endpoint
    let getRes = await client.getPeers()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      # Check peer 2
      getRes.data.anyIt(it.origin == Discv5)
      # Check peer 3
      getRes.data.anyIt(it.origin == PeerExchange)
