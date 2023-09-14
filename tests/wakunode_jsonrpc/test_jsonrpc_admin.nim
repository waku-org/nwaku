{.used.}

import
  std/[options, sequtils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  eth/keys,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/waku_core,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_node,
  ../../../waku/node/jsonrpc/admin/handlers as admin_api,
  ../../../waku/node/jsonrpc/admin/client as admin_api_client,
  ../../../waku/waku_relay,
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/queue_driver,
  ../../../waku/waku_store,
  ../../../waku/waku_filter,
  ../testlib/wakucore,
  ../testlib/wakunode


procSuite "Waku v2 JSON-RPC API - Admin":
  let
    bindIp = ValidIpAddress.init("0.0.0.0")

  asyncTest "connect to ad-hoc peers":
    # Create a couple of nodes
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(60600))
      node2 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(60602))
      peerInfo2 = node2.switch.peerInfo
      node3 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(60604))
      peerInfo3 = node3.switch.peerInfo

    await allFutures([node1.start(), node2.start(), node3.start()])

    await node1.mountRelay()
    await node2.mountRelay()
    await node3.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8551)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installAdminApiHandlers(node1, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    # Connect to nodes 2 and 3 using the Admin API
    let postRes = await client.post_waku_v2_admin_v1_peers(@[constructMultiaddrStr(peerInfo2),
                                                             constructMultiaddrStr(peerInfo3)])

    check:
      postRes

    # Verify that newly connected peers are being managed
    let getRes = await client.get_waku_v2_admin_v1_peers()

    check:
      getRes.len == 2
      # Check peer 2
      getRes.anyIt(it.protocol == WakuRelayCodec and
                   it.multiaddr == constructMultiaddrStr(peerInfo2))
      # Check peer 3
      getRes.anyIt(it.protocol == WakuRelayCodec and
                   it.multiaddr == constructMultiaddrStr(peerInfo3))

    # Verify that raises an exception if we can't connect to the peer
    let nonExistentPeer = "/ip4/0.0.0.0/tcp/10000/p2p/16Uiu2HAm6HZZr7aToTvEBPpiys4UxajCTU97zj5v7RNR2gbniy1D"
    expect(ValueError):
      discard await client.post_waku_v2_admin_v1_peers(@[nonExistentPeer])

    let malformedPeer = "/malformed/peer"
    expect(ValueError):
      discard await client.post_waku_v2_admin_v1_peers(@[malformedPeer])

    await server.stop()
    await server.closeWait()

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "get managed peer information":
    # Create 3 nodes and start them with relay
    let nodes = toSeq(0..<3).mapIt(newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("127.0.0.1"), Port(60220+it*2)))
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Dial nodes 2 and 3 from node1
    await nodes[0].connectToNodes(@[constructMultiaddrStr(nodes[1].peerInfo)])
    await nodes[0].connectToNodes(@[constructMultiaddrStr(nodes[2].peerInfo)])

    # RPC server setup
    let
      rpcPort = Port(8552)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installAdminApiHandlers(nodes[0], server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    let response = await client.get_waku_v2_admin_v1_peers()

    check:
      response.len == 2
      # Check peer 2
      response.anyIt(it.protocol == WakuRelayCodec and
                     it.multiaddr == constructMultiaddrStr(nodes[1].peerInfo))
      # Check peer 3
      response.anyIt(it.protocol == WakuRelayCodec and
                     it.multiaddr == constructMultiaddrStr(nodes[2].peerInfo))

    # Artificially remove the address from the book
    nodes[0].peerManager.peerStore[AddressBook][nodes[1].peerInfo.peerId] = @[]
    nodes[0].peerManager.peerStore[AddressBook][nodes[2].peerInfo.peerId] = @[]

    # Verify that the returned addresses are empty
    let responseEmptyAdd = await client.get_waku_v2_admin_v1_peers()
    check:
      responseEmptyAdd[0].multiaddr == ""
      responseEmptyAdd[1].multiaddr == ""

    await server.stop()
    await server.closeWait()

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "get unmanaged peer information":
    let node = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(60523))

    await node.start()

    # RPC server setup
    let
      rpcPort = Port(8553)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installAdminApiHandlers(node, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    await node.mountFilter()
    await node.mountFilterClient()
    let driver: ArchiveDriver = QueueDriver.new()
    let mountArchiveRes = node.mountArchive(driver)
    assert mountArchiveRes.isOk(), mountArchiveRes.error

    await node.mountStore()
    node.mountStoreClient()

    # Create and set some peers
    let
      locationAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()

      filterPeer = PeerInfo.new(generateEcdsaKey(), @[locationAddr])
      storePeer = PeerInfo.new(generateEcdsaKey(), @[locationAddr])

    node.peerManager.addServicePeer(filterPeer.toRemotePeerInfo(), WakuLegacyFilterCodec)
    node.peerManager.addServicePeer(storePeer.toRemotePeerInfo(), WakuStoreCodec)

    # Mock that we connected in the past so Identify populated this
    node.peerManager.peerStore[ProtoBook][filterPeer.peerId] = @[WakuLegacyFilterCodec]
    node.peerManager.peerStore[ProtoBook][storePeer.peerId] = @[WakuStoreCodec]

    let response = await client.get_waku_v2_admin_v1_peers()

    ## Then
    check:
      response.len == 2
      # Check filter peer
      (response.filterIt(it.protocol == WakuLegacyFilterCodec)[0]).multiaddr == constructMultiaddrStr(filterPeer)
      # Check store peer
      (response.filterIt(it.protocol == WakuStoreCodec)[0]).multiaddr == constructMultiaddrStr(storePeer)

    ## Cleanup
    await server.stop()
    await server.closeWait()

    await node.stop()
