{.used.}

import
  std/[options, sets, tables, os, strutils, sequtils, times],
  chronicles,
  testutils/unittests, stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  eth/keys, eth/common/eth_types,
  libp2p/[builders, switch, multiaddress],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message
import
  ../../waku/v1/node/rpc/hexstrings,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/node/jsonrpc/[store_api,
                              relay_api,
                              debug_api,
                              filter_api,
                              admin_api,
                              private_api],
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_relay,
  ../../waku/v2/protocol/waku_archive,
  ../../waku/v2/protocol/waku_archive/driver/queue_driver,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_store/rpc,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_filter/rpc,
  ../../waku/v2/protocol/waku_filter/client,
  ../../waku/v2/utils/peers,
  ../../waku/v2/utils/time,
  ./testlib/common

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]
const sigPath = sourceDir / ParDir / ParDir / "waku" / "v2" / "node" / "jsonrpc" / "jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigPath)

proc put(store: ArchiveDriver, pubsubTopic: PubsubTopic, message: WakuMessage): Result[void, string] =
  let
    digest = waku_archive.computeDigest(message)
    receivedTime = if message.timestamp > 0: message.timestamp
                  else: getNanosecondTime(getTime().toUnixFloat())

  store.put(pubsubTopic, message, digest, receivedTime)

procSuite "Waku v2 JSON-RPC API":
  let
    rng = crypto.newRng()
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(9000)
    node = WakuNode.new(privkey, bindIp, port, some(extIp), some(port))

  asyncTest "Debug API: get node info":
    await node.start()

    await node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8546)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installDebugApiHandlers(node, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    let response = await client.get_waku_v2_debug_v1_info()

    check:
      response.listenAddresses == @[$node.switch.peerInfo.addrs[^1] & "/p2p/" & $node.switch.peerInfo.peerId]

    await server.stop()
    await server.closeWait()

    await node.stop()

  asyncTest "Relay API: publish and subscribe/unsubscribe":
    await node.start()

    await node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8547)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installRelayApiHandlers(node, server, newTable[string, seq[WakuMessage]]())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    check:
      # At this stage the node is only subscribed to the default topic
      PubSub(node.wakuRelay).topics.len == 1

    # Subscribe to new topics
    let newTopics = @["1","2","3"]
    var response = await client.post_waku_v2_relay_v1_subscriptions(newTopics)

    check:
      # Node is now subscribed to default + new topics
      PubSub(node.wakuRelay).topics.len == 1 + newTopics.len
      response == true

    # Publish a message on the default topic
    response = await client.post_waku_v2_relay_v1_message(DefaultPubsubTopic, WakuRelayMessage(payload: @[byte 1], contentTopic: some(DefaultContentTopic), timestamp: some(getNanosecondTime(epochTime()))))

    check:
      # @TODO poll topic to verify message has been published
      response == true

    # Unsubscribe from new topics
    response = await client.delete_waku_v2_relay_v1_subscriptions(newTopics)

    check:
      # Node is now unsubscribed from new topics
      PubSub(node.wakuRelay).topics.len == 1
      response == true

    await server.stop()
    await server.closeWait()

    await node.stop()

  asyncTest "Relay API: get latest messages":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(60300))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(60302))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(60303), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = DefaultContentTopic
      payload1 = @[byte 9]
      message1 = WakuMessage(payload: payload1, contentTopic: contentTopic)
      payload2 = @[byte 8]
      message2 = WakuMessage(payload: payload2, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # RPC server setup
    let
      rpcPort = Port(8548)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    # Let's connect to node 3 via the API
    installRelayApiHandlers(node3, server, newTable[string, seq[WakuMessage]]())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    # First see if we can retrieve messages published on the default topic (node is already subscribed)
    await node2.publish(DefaultPubsubTopic, message1)

    await sleepAsync(100.millis)

    var messages = await client.get_waku_v2_relay_v1_messages(DefaultPubsubTopic)

    check:
      messages.len == 1
      messages[0].contentTopic == contentTopic
      messages[0].payload == payload1

    # Ensure that read messages are cleared from cache
    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)
    check:
      messages.len == 0

    # Now try to subscribe using API

    var response = await client.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(100.millis)

    check:
      # Node is now subscribed to pubSubTopic
      response == true

    # Now publish a message on node1 and see if we receive it on node3
    await node1.publish(pubSubTopic, message2)

    await sleepAsync(100.millis)

    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)

    check:
      messages.len == 1
      messages[0].contentTopic == contentTopic
      messages[0].payload == payload2

    # Ensure that read messages are cleared from cache
    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)
    check:
      messages.len == 0

    await server.stop()
    await server.closeWait()

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "Store API: retrieve historical messages":
    await node.start()

    await node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8549)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installStoreApiHandlers(node, server)
    server.start()

    # WakuStore setup
    let
      key = crypto.PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)

    let driver: ArchiveDriver = QueueDriver.new()
    node.mountArchive(some(driver), none(MessageValidator), none(RetentionPolicy))
    await node.mountStore()
    node.mountStoreClient()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    node.setStorePeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(node.wakuRelay)
    listenSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    let msgList = @[
      fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("2"), ts=0),
      fakeWakuMessage(@[byte 1], ts=1),
      fakeWakuMessage(@[byte 2], ts=2),
      fakeWakuMessage(@[byte 3], ts=3),
      fakeWakuMessage(@[byte 4], ts=4),
      fakeWakuMessage(@[byte 5], ts=5),
      fakeWakuMessage(@[byte 6], ts=6),
      fakeWakuMessage(@[byte 7], ts=7),
      fakeWakuMessage(@[byte 8], ts=8),
      fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("2"), ts=9)
    ]

    for msg in msgList:
      require driver.put(DefaultPubsubTopic, msg).isOk()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    let response = await client.get_waku_v2_store_v1_messages(some(DefaultPubsubTopic), some(@[HistoryContentFilterRPC(contentTopic: DefaultContentTopic)]), some(Timestamp(0)), some(Timestamp(9)), some(StorePagingOptions()))
    check:
      response.messages.len() == 8
      response.pagingOptions.isNone()

    await server.stop()
    await server.closeWait()

    await node.stop()

  asyncTest "Filter API: subscribe/unsubscribe":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(60390))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(60392))

    await allFutures(node1.start(), node2.start())

    await node1.mountFilter()
    await node2.mountFilterClient()

    node2.setFilterPeer(node1.peerInfo.toRemotePeerInfo())

    # RPC server setup
    let
      rpcPort = Port(8550)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installFilterApiHandlers(node2, server, newTable[ContentTopic, seq[WakuMessage]]())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    check:
      # Light node has not yet subscribed to any filters
      node2.wakuFilterClient.getSubscriptionsCount() == 0

    let contentFilters = @[
      ContentFilter(contentTopic: DefaultContentTopic),
      ContentFilter(contentTopic: ContentTopic("2")),
      ContentFilter(contentTopic: ContentTopic("3")),
      ContentFilter(contentTopic: ContentTopic("4")),
    ]
    var response = await client.post_waku_v2_filter_v1_subscription(contentFilters=contentFilters, topic=some(DefaultPubsubTopic))
    check:
      response == true
      # Light node has successfully subscribed to 4 content topics
      node2.wakuFilterClient.getSubscriptionsCount() == 4

    response = await client.delete_waku_v2_filter_v1_subscription(contentFilters=contentFilters, topic=some(DefaultPubsubTopic))
    check:
      response ==  true
      # Light node has successfully unsubscribed from all filters
      node2.wakuFilterClient.getSubscriptionsCount() == 0

    ## Cleanup
    await server.stop()
    await server.closeWait()

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Admin API: connect to ad-hoc peers":
    # Create a couple of nodes
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60600))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60602))
      peerInfo2 = node2.switch.peerInfo
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60604))
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

  asyncTest "Admin API: get managed peer information":
    # Create a couple of nodes
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60220))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60222))
      peerInfo2 = node2.peerInfo
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60224))
      peerInfo3 = node3.peerInfo

    await allFutures([node1.start(), node2.start(), node3.start()])

    await node1.mountRelay()
    await node2.mountRelay()
    await node3.mountRelay()

    # Dial nodes 2 and 3 from node1
    await node1.connectToNodes(@[constructMultiaddrStr(peerInfo2)])
    await node1.connectToNodes(@[constructMultiaddrStr(peerInfo3)])

    # RPC server setup
    let
      rpcPort = Port(8552)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installAdminApiHandlers(node1, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    let response = await client.get_waku_v2_admin_v1_peers()

    check:
      response.len == 2
      # Check peer 2
      response.anyIt(it.protocol == WakuRelayCodec and
                     it.multiaddr == constructMultiaddrStr(peerInfo2))
      # Check peer 3
      response.anyIt(it.protocol == WakuRelayCodec and
                     it.multiaddr == constructMultiaddrStr(peerInfo3))

    await server.stop()
    await server.closeWait()

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Admin API: get unmanaged peer information":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60523))

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
    await node.mountSwap()
    let driver: ArchiveDriver = QueueDriver.new()
    node.mountArchive(some(driver), none(MessageValidator), none(RetentionPolicy))
    await node.mountStore()
    node.mountStoreClient()

    # Create and set some peers
    let
      locationAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()

      filterKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      filterPeer = PeerInfo.new(filterKey, @[locationAddr])

      swapKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      swapPeer = PeerInfo.new(swapKey, @[locationAddr])

      storeKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      storePeer = PeerInfo.new(storeKey, @[locationAddr])

    node.wakuSwap.setPeer(swapPeer.toRemotePeerInfo())
    node.setStorePeer(storePeer.toRemotePeerInfo())
    node.setFilterPeer(filterPeer.toRemotePeerInfo())

    let response = await client.get_waku_v2_admin_v1_peers()

    ## Then
    check:
      response.len == 3
      # Check filter peer
      (response.filterIt(it.protocol == WakuFilterCodec)[0]).multiaddr == constructMultiaddrStr(filterPeer)
      # Check swap peer
      (response.filterIt(it.protocol == WakuSwapCodec)[0]).multiaddr == constructMultiaddrStr(swapPeer)
      # Check store peer
      (response.filterIt(it.protocol == WakuStoreCodec)[0]).multiaddr == constructMultiaddrStr(storePeer)

    ## Cleanup
    await server.stop()
    await server.closeWait()

    await node.stop()

  asyncTest "Private API: generate asymmetric keys and encrypt/decrypt communication":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(62001))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(62002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(62003), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = DefaultContentTopic
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic), timestamp: some(getNanosecondTime(epochTime())))
      topicCache = newTable[string, seq[WakuMessage]]()

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      rpcPort1 = Port(8554)
      ta1 = initTAddress(bindIp, rpcPort1)
      server1 = newRpcHttpServer([ta1])
      rpcPort3 = Port(8555)
      ta3 = initTAddress(bindIp, rpcPort3)
      server3 = newRpcHttpServer([ta3])

    # Let's connect to nodes 1 and 3 via the API
    installPrivateApiHandlers(node1, server1, newTable[string, seq[WakuMessage]]())
    installPrivateApiHandlers(node3, server3, topicCache)
    installRelayApiHandlers(node3, server3, topicCache)
    server1.start()
    server3.start()

    let client1 = newRpcHttpClient()
    await client1.connect("127.0.0.1", rpcPort1, false)

    let client3 = newRpcHttpClient()
    await client3.connect("127.0.0.1", rpcPort3, false)

    # Let's get a keypair for node3

    let keypair = await client3.get_waku_v2_private_v1_asymmetric_keypair()

    # Now try to subscribe on node3 using API

    let sub = await client3.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(100.millis)

    check:
      # node3 is now subscribed to pubSubTopic
      sub

    # Now publish and encrypt a message on node1 using node3's public key
    let posted = await client1.post_waku_v2_private_v1_asymmetric_message(pubSubTopic, message, publicKey = (%keypair.pubkey).getStr())
    check:
      posted

    await sleepAsync(100.millis)

    # Let's see if we can receive, and decrypt, this message on node3
    var messages = await client3.get_waku_v2_private_v1_asymmetric_messages(pubSubTopic, privateKey = (%keypair.seckey).getStr())

    check:
      messages.len == 1
      messages[0].contentTopic.get == contentTopic
      messages[0].payload == payload

    # Ensure that read messages are cleared from cache
    messages = await client3.get_waku_v2_private_v1_asymmetric_messages(pubSubTopic, privateKey = (%keypair.seckey).getStr())
    check:
      messages.len == 0

    await server1.stop()
    await server1.closeWait()
    await server3.stop()
    await server3.closeWait()

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "Private API: generate symmetric keys and encrypt/decrypt communication":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(62100))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(62102))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(62103), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = DefaultContentTopic
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic), timestamp: some(getNanosecondTime(epochTime())))
      topicCache = newTable[string, seq[WakuMessage]]()

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      rpcPort1 = Port(8556)
      ta1 = initTAddress(bindIp, rpcPort1)
      server1 = newRpcHttpServer([ta1])
      rpcPort3 = Port(8557)
      ta3 = initTAddress(bindIp, rpcPort3)
      server3 = newRpcHttpServer([ta3])

    # Let's connect to nodes 1 and 3 via the API
    installPrivateApiHandlers(node1, server1, newTable[string, seq[WakuMessage]]())
    installPrivateApiHandlers(node3, server3, topicCache)
    installRelayApiHandlers(node3, server3, topicCache)
    server1.start()
    server3.start()

    let client1 = newRpcHttpClient()
    await client1.connect("127.0.0.1", rpcPort1, false)

    let client3 = newRpcHttpClient()
    await client3.connect("127.0.0.1", rpcPort3, false)

    # Let's get a symkey for node3

    let symkey = await client3.get_waku_v2_private_v1_symmetric_key()

    # Now try to subscribe on node3 using API

    let sub = await client3.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(100.millis)

    check:
      # node3 is now subscribed to pubSubTopic
      sub

    # Now publish and encrypt a message on node1 using node3's symkey
    let posted = await client1.post_waku_v2_private_v1_symmetric_message(pubSubTopic, message, symkey = (%symkey).getStr())
    check:
      posted

    await sleepAsync(100.millis)

    # Let's see if we can receive, and decrypt, this message on node3
    var messages = await client3.get_waku_v2_private_v1_symmetric_messages(pubSubTopic, symkey = (%symkey).getStr())

    check:
      messages.len == 1
      messages[0].contentTopic.get == contentTopic
      messages[0].payload == payload

    # Ensure that read messages are cleared from cache
    messages = await client3.get_waku_v2_private_v1_symmetric_messages(pubSubTopic, symkey = (%symkey).getStr())
    check:
      messages.len == 0

    await server1.stop()
    await server1.closeWait()
    await server3.stop()
    await server3.closeWait()

    await node1.stop()
    await node2.stop()
    await node3.stop()
