import
  std/[unittest, options, sets, tables, os, strutils],
  stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  libp2p/standard_setup,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message,
  ../../waku/v2/waku_types,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/jsonrpc/[jsonrpc_types,store_api,relay_api,debug_api,filter_api],
  ../../waku/v2/protocol/message_notifier,
  ../../waku/v2/protocol/waku_store/waku_store,
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

    waitFor node.mountRelay()

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
      response.listenStr == $node.peerInfo.addrs[0] & "/p2p/" & $node.peerInfo.peerId

    server.stop()
    server.close()
    waitfor node.stop()

  asyncTest "Relay API: publish and subscribe/unsubscribe": 
    waitFor node.start()

    waitFor node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installRelayApiHandlers(node, server)
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
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo])
    await node3.connectToNodes(@[node2.peerInfo])

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])
    
    # Let's connect to node 3 via the API
    installRelayApiHandlers(node3, server)
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
    node1.publish(pubSubTopic, message)

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

    waitFor node.mountRelay(@[defaultTopic])

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

    waitFor node.mountRelay()

    node.mountFilter()

    # RPC server setup
    let
      rpcPort = Port(8545)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installFilterApiHandlers(node, server)
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
