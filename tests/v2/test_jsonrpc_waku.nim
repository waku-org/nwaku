import
  std/[unittest, options, sets, tables, os, strutils, sequtils],
  stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  eth/[keys, rlp], eth/common/eth_types,
  libp2p/[standard_setup, switch, multiaddress],
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
  ../../waku/v2/protocol/message_notifier,
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../test_helpers

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]
const sigPath = sourceDir / ParDir / ParDir / "waku" / "v2" / "node" / "jsonrpc" / "jsonrpc_callsigs.nim"
createRpcSigs(RpcHttpClient, sigPath)

procSuite "Waku v2 JSON-RPC API":
  const defaultTopic = "/waku/2/default-waku/proto"
  const testCodec = "/waku/2/default-waku/codec"

  let
    rng = crypto.newRng()
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(9000)
    node = WakuNode.init(privkey, bindIp, port, some(extIp), some(port))

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
      response.listenStr == $node.peerInfo.addrs[^1] & "/p2p/" & $node.peerInfo.peerId

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
    response = await client.post_waku_v2_relay_v1_message(defaultTopic, WakuRelayMessage(payload: @[byte 1], contentTopic: some(ContentTopic(1))))

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
      node1 = WakuNode.init(nodeKey1, bindIp, Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, bindIp, Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, bindIp, Port(60003), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = ContentTopic(1)
      payload = @[byte 9]
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo])
    await node3.connectToNodes(@[node2.peerInfo])

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

    # Now try to subscribe using API

    var response = await client.post_waku_v2_relay_v1_subscriptions(@[pubSubTopic])

    await sleepAsync(2000.millis)

    check:
      # Node is now subscribed to pubSubTopic
      response == true

    # Now publish a message on node1 and see if we receive it on node3
    await node1.publish(pubSubTopic, message)

    await sleepAsync(2000.millis)
    
    var messages = await client.get_waku_v2_relay_v1_messages(pubSubTopic)

    check:
      messages.len == 1
      messages[0].contentTopic == contentTopic
      messages[0].payload == payload
    
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

    node.mountRelay(@[defaultTopic])

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
      peer = PeerInfo.init(key)
    
    node.mountStore()
    let
      subscription = node.wakuStore.subscription()
    
    var listenSwitch = newStandardSwitch(some(key))
    discard waitFor listenSwitch.start()

    node.wakuStore.setPeer(listenSwitch.peerInfo)

    listenSwitch.mount(node.wakuStore)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions[testCodec] = subscription

    # Now prime it with some history before tests
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic(2)),
        WakuMessage(payload: @[byte 1], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 2], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 3], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 4], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 5], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 6], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 7], contentTopic: ContentTopic(1)),
        WakuMessage(payload: @[byte 8], contentTopic: ContentTopic(1)), 
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic(2))]

    for wakuMsg in msgList:
      waitFor subscriptions.notify(defaultTopic, wakuMsg)

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    let response = await client.get_waku_v2_store_v1_messages(@[ContentTopic(1)], some(StorePagingOptions()))
    check:
      response.messages.len() == 8
      response.pagingOptions.isNone
      
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

    let contentFilters = @[ContentFilter(topics: @[ContentTopic(1), ContentTopic(2)]),
                           ContentFilter(topics: @[ContentTopic(3), ContentTopic(4)])]
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
    const cTopic = ContentTopic(1)

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

    let sub = await client.post_waku_v2_filter_v1_subscription(contentFilters = @[ContentFilter(topics: @[cTopic])], topic = some(defaultTopic))
    check:
      sub

    # Now prime the node with some messages before tests
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic(2)),
        WakuMessage(payload: @[byte 1], contentTopic: cTopic),
        WakuMessage(payload: @[byte 2], contentTopic: cTopic),
        WakuMessage(payload: @[byte 3], contentTopic: cTopic),
        WakuMessage(payload: @[byte 4], contentTopic: cTopic),
        WakuMessage(payload: @[byte 5], contentTopic: cTopic),
        WakuMessage(payload: @[byte 6], contentTopic: cTopic),
        WakuMessage(payload: @[byte 7], contentTopic: cTopic),
        WakuMessage(payload: @[byte 8], contentTopic: cTopic), 
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic(2))]

    let
      filters = node.filters
      requestId = toSeq(Table(filters).keys)[0]

    for wakuMsg in msgList:
      filters.notify(wakuMsg, requestId)

    var response = await client.get_waku_v2_filter_v1_messages(cTopic)
    check:
      response.len() == 8
      response.allIt(it.contentTopic == cTopic)

    # No new messages
    response = await client.get_waku_v2_filter_v1_messages(cTopic)

    check:
      response.len() == 0
    
    # Now ensure that no more than the preset max messages can be cached

    let maxSize = filter_api.maxCache

    for x in 1..(maxSize + 1):
      # Try to cache 1 more than maximum allowed
      filters.notify(WakuMessage(payload: @[byte x], contentTopic: cTopic), requestId)

    response = await client.get_waku_v2_filter_v1_messages(cTopic)
    check:
      # Max messages has not been exceeded
      response.len == maxSize
      response.allIt(it.contentTopic == cTopic)
      # Check that oldest item has been removed
      response[0].payload == @[byte 2]
      response[maxSize - 1].payload == @[byte (maxSize + 1)]

    server.stop()
    server.close()
    waitfor node.stop()
  
  asyncTest "Admin API: get peer information":
    const cTopic = ContentTopic(1)

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
    node.mountStore()

    # Create and set some peers
    let
      locationAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()

      filterKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      filterPeer = PeerInfo.init(filterKey, @[locationAddr])

      swapKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      swapPeer = PeerInfo.init(swapKey, @[locationAddr])

      storeKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      storePeer = PeerInfo.init(storeKey, @[locationAddr])

    node.wakuFilter.setPeer(filterPeer)
    node.wakuSwap.setPeer(swapPeer)
    node.wakuStore.setPeer(storePeer)

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
      node1 = WakuNode.init(nodeKey1, bindIp, Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, bindIp, Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, bindIp, Port(60003), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = ContentTopic(1)
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic))
      topicCache = newTable[string, seq[WakuMessage]]()

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo])
    await node3.connectToNodes(@[node2.peerInfo])

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
      node1 = WakuNode.init(nodeKey1, bindIp, Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, bindIp, Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, bindIp, Port(60003), some(extIp), some(port))
      pubSubTopic = "polling"
      contentTopic = ContentTopic(1)
      payload = @[byte 9]
      message = WakuRelayMessage(payload: payload, contentTopic: some(contentTopic))
      topicCache = newTable[string, seq[WakuMessage]]()

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo])
    await node3.connectToNodes(@[node2.peerInfo])

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
