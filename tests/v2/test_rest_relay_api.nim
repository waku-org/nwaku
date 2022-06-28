{.used.}

import
  std/sequtils,
  stew/byteutils,
  stew/shims/net,
  chronicles,
  testutils/unittests,
  presto,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub
import
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/rest/[server, client, utils],
  ../../waku/v2/node/rest/relay/[api_types, relay_api, topic_cache]


proc testWakuNode(): WakuNode = 
  let 
    rng = crypto.newRng()
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(9000)

  WakuNode.new(privkey, bindIp, port, some(extIp), some(port))

proc fakeWakuMessage(payload = toBytes("TEST"), contentTopic = "test"): WakuMessage = 
  WakuMessage(
    payload: payload,
    contentTopic: contentTopic,
    version: 1,
    timestamp: 2022
  )


suite "REST API - Relay":
  asyncTest "Subscribe a node to an array of topics - POST /relay/v1/subscriptions": 
    # Given
    let node = testWakuNode()
    await node.start()
    node.mountRelay()

    let restPort = Port(8546)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let topicCache = TopicCache.init()

    installRelayPostSubscriptionsV1Handler(restServer.router, node, topicCache)
    restServer.start()

    let pubSubTopics = @[
      PubSubTopicString("pubsub-topic-1"), 
      PubSubTopicString("pubsub-topic-2"),
      PubSubTopicString("pubsub-topic-3")
    ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let requestBody = RelayPostSubscriptionsRequest(pubSubTopics)
    let response = await client.relayPostSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      topicCache.isSubscribed("pubsub-topic-1")
      topicCache.isSubscribed("pubsub-topic-2")
      topicCache.isSubscribed("pubsub-topic-3")

    check:
      # Node should be subscribed to default + new topics
      PubSub(node.wakuRelay).topics.len == 1 + pubSubTopics.len
      
    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of topics - DELETE /relay/v1/subscriptions": 
    # Given
    let node = testWakuNode()
    await node.start()
    node.mountRelay()

    let restPort = Port(8546)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let topicCache = TopicCache.init()
    topicCache.subscribe("pubsub-topic-1")
    topicCache.subscribe("pubsub-topic-2")
    topicCache.subscribe("pubsub-topic-3")
    topicCache.subscribe("pubsub-topic-x")

    installRelayDeleteSubscriptionsV1Handler(restServer.router, node, topicCache)
    restServer.start()

    let pubSubTopics = @[
      PubSubTopicString("pubsub-topic-1"), 
      PubSubTopicString("pubsub-topic-2"),
      PubSubTopicString("pubsub-topic-3"),
      PubSubTopicString("pubsub-topic-y")
    ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let requestBody = RelayDeleteSubscriptionsRequest(pubSubTopics)
    let response = await client.relayDeleteSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not topicCache.isSubscribed("pubsub-topic-1")
      not topicCache.isSubscribed("pubsub-topic-2")
      not topicCache.isSubscribed("pubsub-topic-3")
      topicCache.isSubscribed("pubsub-topic-x")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()


  asyncTest "Get the latest messages for topic - GET /relay/v1/messages/{topic}": 
    # Given
    let node = testWakuNode()
    await node.start()
    node.mountRelay()

    let restPort = Port(8546)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let pubSubTopic = "/waku/2/default-waku/proto"
    let messages =  @[
      fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1")),
      fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1")),
      fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1")),
    ]

    let topicCache = TopicCache.init()

    topicCache.subscribe(pubSubTopic)
    for msg in messages:
      topicCache.addMessage(pubSubTopic, msg)

    installRelayGetMessagesV1Handler(restServer.router, node, topicCache)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayGetMessagesV1(pubSubTopic)

    # Then
    check:
      response.status == 200
      response.contentType == $MIMETYPE_JSON
      response.data.len == 3
      response.data.all do (msg: RelayWakuMessage) -> bool: 
        msg.payload == "TEST-1" and
        string(msg.contentTopic.get()) == "content-topic-x" and
        msg.version.get() == Natural(1) and
        msg.timestamp.get() == int64(2022)


    check:
      topicCache.isSubscribed(pubSubTopic)
      topicCache.getMessages(pubSubTopic).tryGet().len == 0

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to topic - POST /relay/v1/messages/{topic}": 
    ## "Relay API: publish and subscribe/unsubscribe": 
    # Given
    let node = testWakuNode()
    await node.start()
    node.mountRelay()

    # RPC server setup
    let restPort = Port(8546)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let topicCache = TopicCache.init()

    installRelayApiHandlers(restServer.router, node, topicCache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    const defaultContentTopic = ContentTopic("/waku/2/default-content/proto")
    
    # At this stage the node is only subscribed to the default topic
    require(PubSub(node.wakuRelay).topics.len == 1)
    

    # When
    let newTopics = @[
      PubSubTopicString("pubsub-topic-1"),
      PubSubTopicString("pubsub-topic-2"),
      PubSubTopicString("pubsub-topic-3")
    ]
    discard await client.relayPostSubscriptionsV1(newTopics)
    
    let response = await client.relayPostMessagesV1(defaultTopic, RelayWakuMessage(
      payload: "TEST-PAYLOAD", 
      contentTopic: some(ContentTopicString(defaultContentTopic)), 
      timestamp: some(int64(2022))
    ))

    # Then
    check:
      response.status == 200
      response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    # TODO: Check for the message to be published to the topic

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
