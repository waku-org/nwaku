{.used.}

import
  std/[options, sets, tables, os, strutils, sequtils, times],
  testutils/unittests, stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  eth/[keys, rlp], eth/common/eth_types,
  libp2p/[builders, switch, multiaddress],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message,
  ../../waku/v1/node/rpc/hexstrings,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/jsonrpc/[store_api,
                              relay_api,
                              debug_api,
                              filter_api,
                              admin_api,
                              private_api],
  ../../waku/v2/protocol/waku_relay,
  ../../waku/v2/protocol/waku_store/[waku_store, waku_store_types],
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../../waku/v2/utils/peers,
  ../test_helpers

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]
const sigPath = sourceDir / ParDir / ParDir / "waku" / "v2" / "node" / "jsonrpc" / "jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigPath)

procSuite "Waku v2 JSON-RPC API":
  const defaultTopic = "/waku/2/default-waku/proto"
  const defaultContentTopic = ContentTopic("/waku/2/default-content/proto")
  const testCodec = "/waku/2/default-waku/codec"

  let
    rng = crypto.newRng()
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(9000)
    node = WakuNode.new(privkey, bindIp, port, some(extIp), some(port))

  asyncTest "Debug API: get node info": 
    waitFor node.start()

    node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installDebugApiHandlers(node, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    let response = await client.get_waku_v2_debug_v1_info()

    check:
      response.listenAddresses == @[$node.peerInfo.addrs[^1] & "/p2p/" & $node.peerInfo.peerId]

    server.stop()
    server.close()
    waitfor node.stop()

  asyncTest "Relay API: publish and subscribe/unsubscribe": 
    waitFor node.start()

    node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installRelayApiHandlers(node, server, newTable[string, seq[WakuMessage]]())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)
    
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
    response = await client.post_waku_v2_relay_v1_message(defaultTopic, WakuRelayMessage(payload: @[byte 1], contentTopic: some(defaultContentTopic), timestamp: some(epochTime())))

    check:
      # @TODO poll topic to verify message has been published
      response == true
    
    # Unsubscribe from new topics
    response = await client.delete_waku_v2_relay_v1_subscriptions(newTopics)

    check:
      # Node is now unsubscribed from new topics
      PubSub(node.wakuRelay).topics.len == 1
      response == true

    server.stop()
    server.close()
    waitfor node.stop()
  
  asyncTest "Relay API: get latest messages": 
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(60003), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = defaultContentTopic
      payload1 = @[byte 9]
      message1 = WakuMessage(payload: payload1, contentTopic: contentTopic)
      payload2 = @[byte 8]
      message2 = WakuMessage(payload: payload2, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.peerInfo.toRemotePeerInfo()])

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])
    
    # Let's connect to node 3 via the API
    installRelayApiHandlers(node3, server, newTable[string, seq[WakuMessage]]())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    # First see if we can retrieve messages published on the default topic (node is already subscribed)
    await node2.publish(defaultTopic, message1)

    await sleepAsync(2000.millis)

    var messages = await client.get_waku_v2_relay_v1_messages(defaultTopic)

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

    await sleepAsync(2000.millis)

    check:
      # Node is now subscribed to pubSubTopic
      response == true

    # Now publish a message on node1 and see if we receive it on node3
    await node1.publish(pubSubTopic, message2)

    await sleepAsync(2000.millis)
    
    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)

    check:
      messages.len == 1
      messages[0].contentTopic == contentTopic
      messages[0].payload == payload2
    
    # Ensure that read messages are cleared from cache
    messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)  
    check:
      messages.len == 0

    server.stop()
    server.close()
    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "Store API: retrieve historical messages":      
    waitFor node.start()

    node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installStoreApiHandlers(node, server)
    server.start()

    # WakuStore setup
    let
      key = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
    
    node.mountStore(persistMessages = true)
    
    var listenSwitch = newStandardSwitch(some(key))
    discard waitFor listenSwitch.start()

    node.wakuStore.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(node.wakuRelay)
    listenSwitch.mount(node.wakuStore)

    # Now prime it with some history before tests
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: 0),
        WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic, timestamp: 1),
        WakuMessage(payload: @[byte 2], contentTopic: defaultContentTopic, timestamp: 2),
        WakuMessage(payload: @[byte 3], contentTopic: defaultContentTopic, timestamp: 3),
        WakuMessage(payload: @[byte 4], contentTopic: defaultContentTopic, timestamp: 4),
        WakuMessage(payload: @[byte 5], contentTopic: defaultContentTopic, timestamp: 5),
        WakuMessage(payload: @[byte 6], contentTopic: defaultContentTopic, timestamp: 6),
        WakuMessage(payload: @[byte 7], contentTopic: defaultContentTopic, timestamp: 7),
        WakuMessage(payload: @[byte 8], contentTopic: defaultContentTopic, timestamp: 8), 
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic("2"), timestamp: 9)]

    for wakuMsg in msgList:
      waitFor node.wakuStore.handleMessage(defaultTopic, wakuMsg)

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    let response = await client.get_waku_v2_store_v1_messages(some(defaultTopic), some(@[HistoryContentFilter(contentTopic: defaultContentTopic)]), some(0.float64), some(9.float64), some(StorePagingOptions()))
    check:
      response.messages.len() == 8
      response.pagingOptions.isSome()
      
    server.stop()
    server.close()
    waitfor node.stop()
  
  asyncTest "Filter API: subscribe/unsubscribe": 
    waitFor node.start()

    node.mountRelay()

    node.mountFilter()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installFilterApiHandlers(node, server, newTable[ContentTopic, seq[WakuMessage]]())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    check:
      # Light node has not yet subscribed to any filters
      node.filters.len() == 0

    let contentFilters = @[ContentFilter(contentTopic: defaultContentTopic),
                           ContentFilter(contentTopic: ContentTopic("2")),
                           ContentFilter(contentTopic: ContentTopic("3")),
                           ContentFilter(contentTopic: ContentTopic("4")),
                           ]
    var response = await client.post_waku_v2_filter_v1_subscription(contentFilters = contentFilters, topic = some(defaultTopic))
    
    check:
      # Light node has successfully subscribed to a single filter
      node.filters.len() == 1
      response == true

    response = await client.delete_waku_v2_filter_v1_subscription(contentFilters = contentFilters, topic = some(defaultTopic))
    
    check:
      # Light node has successfully unsubscribed from all filters
      node.filters.len() == 0
      response == true

    server.stop()
    server.close()
    waitfor node.stop()
  
  asyncTest "Filter API: get latest messages":
    waitFor node.start()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installFilterApiHandlers(node, server, newTable[ContentTopic, seq[WakuMessage]]())
    server.start()
    
    node.mountFilter()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    # First ensure subscription exists

    let sub = await client.post_waku_v2_filter_v1_subscription(contentFilters = @[ContentFilter(contentTopic: defaultContentTopic)], topic = some(defaultTopic))
    check:
      sub

    # Now prime the node with some messages before tests
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2")),
        WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 2], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 3], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 4], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 5], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 6], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 7], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 8], contentTopic: defaultContentTopic), 
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic("2"))]

    let
      filters = node.filters
      requestId = toSeq(Table(filters).keys)[0]

    for wakuMsg in msgList:
      filters.notify(wakuMsg, requestId)

    var response = await client.get_waku_v2_filter_v1_messages(defaultContentTopic)
    check:
      response.len() == 8
      response.allIt(it.contentTopic == defaultContentTopic)

    # No new messages
    response = await client.get_waku_v2_filter_v1_messages(defaultContentTopic)

    check:
      response.len() == 0
    
    # Now ensure that no more than the preset max messages can be cached

    let maxSize = filter_api.maxCache

    for x in 1..(maxSize + 1):
      # Try to cache 1 more than maximum allowed
      filters.notify(WakuMessage(payload: @[byte x], contentTopic: defaultContentTopic), requestId)
    
    await sleepAsync(2000.millis)

    response = await client.get_waku_v2_filter_v1_messages(defaultContentTopic)
    check:
      # Max messages has not been exceeded
      response.len == maxSize
      response.allIt(it.contentTopic == defaultContentTopic)
      # Check that oldest item has been removed
      response[0].payload == @[byte 2]
      response[maxSize - 1].payload == @[byte (maxSize + 1)]

    server.stop()
    server.close()
    waitfor node.stop()
  
  asyncTest "Admin API: connect to ad-hoc peers":
    # Create a couple of nodes
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.peerInfo
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60004))
      peerInfo3 = node3.peerInfo
    
    await allFutures([node1.start(), node2.start(), node3.start()])

    node1.mountRelay()
    node2.mountRelay()
    node3.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installAdminApiHandlers(node1, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

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

    server.stop()
    server.close()
    await allFutures([node1.stop(), node2.stop(), node3.stop()])
  
  asyncTest "Admin API: get managed peer information":
    # Create a couple of nodes
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.peerInfo
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60004))
      peerInfo3 = node3.peerInfo
    
    await allFutures([node1.start(), node2.start(), node3.start()])

    node1.mountRelay()
    node2.mountRelay()
    node3.mountRelay()

    # Dial nodes 2 and 3 from node1
    await node1.dialPeer(constructMultiaddrStr(peerInfo2))
    await node1.dialPeer(constructMultiaddrStr(peerInfo3))

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installAdminApiHandlers(node1, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    let response = await client.get_waku_v2_admin_v1_peers()

    check:
      response.len == 2
      # Check peer 2
      response.anyIt(it.protocol == WakuRelayCodec and
                     it.multiaddr == constructMultiaddrStr(peerInfo2))
      # Check peer 3
      response.anyIt(it.protocol == WakuRelayCodec and
                     it.multiaddr == constructMultiaddrStr(peerInfo3))

    server.stop()
    server.close()
    await allFutures([node1.stop(), node2.stop(), node3.stop()])
  
  asyncTest "Admin API: get unmanaged peer information":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))

    waitFor node.start()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installAdminApiHandlers(node, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    node.mountFilter()
    node.mountSwap()
    node.mountStore(persistMessages = true)

    # Create and set some peers
    let
      locationAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()

      filterKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      filterPeer = PeerInfo.new(filterKey, @[locationAddr])

      swapKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      swapPeer = PeerInfo.new(swapKey, @[locationAddr])

      storeKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      storePeer = PeerInfo.new(storeKey, @[locationAddr])

    node.wakuFilter.setPeer(filterPeer.toRemotePeerInfo())
    node.wakuSwap.setPeer(swapPeer.toRemotePeerInfo())
    node.wakuStore.setPeer(storePeer.toRemotePeerInfo())

    let response = await client.get_waku_v2_admin_v1_peers()

    check:
      response.len == 3
      # Check filter peer
      (response.filterIt(it.protocol == WakuFilterCodec)[0]).multiaddr == constructMultiaddrStr(filterPeer)
      # Check swap peer
      (response.filterIt(it.protocol == WakuSwapCodec)[0]).multiaddr == constructMultiaddrStr(swapPeer)
      # Check store peer
      (response.filterIt(it.protocol == WakuStoreCodec)[0]).multiaddr == constructMultiaddrStr(storePeer)

    server.stop()
    server.close()
    waitfor node.stop()

  asyncTest "Private API: generate asymmetric keys and encrypt/decrypt communication":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(60003), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = defaultContentTopic
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic), timestamp: some(epochTime()))
      topicCache = newTable[string, seq[WakuMessage]]()

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      rpcPort1 = Port(8545)
      ta1 = initTAddress(bindIp, rpcPort1)
      server1 = newRpcHttpServer([ta1])
      rpcPort3 = Port(8546)
      ta3 = initTAddress(bindIp, rpcPort3)
      server3 = newRpcHttpServer([ta3])
    
    # Let's connect to nodes 1 and 3 via the API
    installPrivateApiHandlers(node1, server1, rng, newTable[string, seq[WakuMessage]]())
    installPrivateApiHandlers(node3, server3, rng, topicCache)
    installRelayApiHandlers(node3, server3, topicCache)
    server1.start()
    server3.start()

    let client1 = newRpcHttpClient()
    await client1.connect("127.0.0.1", rpcPort1)

    let client3 = newRpcHttpClient()
    await client3.connect("127.0.0.1", rpcPort3)

    # Let's get a keypair for node3

    let keypair = await client3.get_waku_v2_private_v1_asymmetric_keypair()

    # Now try to subscribe on node3 using API

    let sub = await client3.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(2000.millis)

    check:
      # node3 is now subscribed to pubSubTopic
      sub

    # Now publish and encrypt a message on node1 using node3's public key
    let posted = await client1.post_waku_v2_private_v1_asymmetric_message(pubSubTopic, message, publicKey = (%keypair.pubkey).getStr())
    check:
      posted

    await sleepAsync(2000.millis)

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

    server1.stop()
    server1.close()
    server3.stop()
    server3.close()
    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "Private API: generate symmetric keys and encrypt/decrypt communication":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(60003), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = defaultContentTopic
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic), timestamp: some(epochTime()))
      topicCache = newTable[string, seq[WakuMessage]]()

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.peerInfo.toRemotePeerInfo()])

    # Setup two servers so we can see both sides of encrypted communication
    let
      rpcPort1 = Port(8545)
      ta1 = initTAddress(bindIp, rpcPort1)
      server1 = newRpcHttpServer([ta1])
      rpcPort3 = Port(8546)
      ta3 = initTAddress(bindIp, rpcPort3)
      server3 = newRpcHttpServer([ta3])
    
    # Let's connect to nodes 1 and 3 via the API
    installPrivateApiHandlers(node1, server1, rng, newTable[string, seq[WakuMessage]]())
    installPrivateApiHandlers(node3, server3, rng, topicCache)
    installRelayApiHandlers(node3, server3, topicCache)
    server1.start()
    server3.start()

    let client1 = newRpcHttpClient()
    await client1.connect("127.0.0.1", rpcPort1)

    let client3 = newRpcHttpClient()
    await client3.connect("127.0.0.1", rpcPort3)

    # Let's get a symkey for node3

    let symkey = await client3.get_waku_v2_private_v1_symmetric_key()

    # Now try to subscribe on node3 using API

    let sub = await client3.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(2000.millis)

    check:
      # node3 is now subscribed to pubSubTopic
      sub

    # Now publish and encrypt a message on node1 using node3's symkey
    let posted = await client1.post_waku_v2_private_v1_symmetric_message(pubSubTopic, message, symkey = (%symkey).getStr())
    check:
      posted

    await sleepAsync(2000.millis)

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

    server1.stop()
    server1.close()
    server3.stop()
    server3.close()
    await node1.stop()
    await node2.stop()
    await node3.stop()