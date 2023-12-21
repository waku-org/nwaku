{.used.}

import
  std/[sequtils,strformat],
  stew/shims/net,
  testutils/unittests,
  presto, presto/client as presto_client,
  libp2p/crypto/crypto

import
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/waku_filter_v2/client,
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
  var peerInfo1 {.threadvar.}: RemotePeerInfo
  var peerInfo2 {.threadvar.}: RemotePeerInfo
  var peerInfo3 {.threadvar.}: RemotePeerInfo
  var restServer {.threadvar.}: RestServerRef
  var client{.threadvar.}: RestClientRef

  asyncSetup:
    node1 = newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(60600))
    peerInfo1 = node1.switch.peerInfo
    node2 = newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(60602))
    peerInfo2 = node2.switch.peerInfo
    node3 = newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(60604))
    peerInfo3 = node3.switch.peerInfo

    await allFutures(node1.start(), node2.start(), node3.start())
    await allFutures(node1.mountRelay(), node2.mountRelay(), node3.mountRelay())

    let restPort = Port(58011)
    let restAddress = parseIpAddress("127.0.0.1")
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

  asyncTest "Get filter data":
    await allFutures(node1.mountFilter(), node2.mountFilterClient(), node3.mountFilterClient())

    let
      contentFiltersNode2 = @[DefaultContentTopic, ContentTopic("2"), ContentTopic("3")]
      contentFiltersNode3 = @[ContentTopic("3"), ContentTopic("4")]
      pubsubTopicNode2 = DefaultPubsubTopic
      pubsubTopicNode3 = PubsubTopic("/waku/2/custom-waku/proto")

      expectedFilterData2 = fmt"(peerId: ""{$peerInfo2}"", filterCriteria:" &
        fmt" @[(pubsubTopic: ""{pubsubTopicNode2}"", contentTopic: ""{contentFiltersNode2[0]}""), " &
        fmt"(pubsubTopic: ""{pubsubTopicNode2}"", contentTopic: ""{contentFiltersNode2[1]}""), " &
        fmt"(pubsubTopic: ""{pubsubTopicNode2}"", contentTopic: ""{contentFiltersNode2[2]}"")]"

      expectedFilterData3 = fmt"(peerId: ""{$peerInfo3}"", filterCriteria:" &
        fmt" @[(pubsubTopic: ""{pubsubTopicNode3}"", contentTopic: ""{contentFiltersNode3[0]}""), " &
        fmt"(pubsubTopic: ""{pubsubTopicNode3}"", contentTopic: ""{contentFiltersNode3[1]}"")]"

    let
      subscribeResponse2 = await node2.wakuFilterClient.subscribe(
        peerInfo1, pubsubTopicNode2, contentFiltersNode2
      )
      subscribeResponse3 = await node3.wakuFilterClient.subscribe(
        peerInfo1, pubsubTopicNode3, contentFiltersNode3
      )

    assert subscribeResponse2.isOk(), $subscribeResponse2.error
    assert subscribeResponse3.isOk(), $subscribeResponse3.error

    let getRes = await client.getFilterData()

    check:
      getRes.status == 200
      $getRes.contentType == $MIMETYPE_JSON
      getRes.data.len() == 2
      ($getRes.data).contains(expectedFilterData2)
      ($getRes.data).contains(expectedFilterData3)