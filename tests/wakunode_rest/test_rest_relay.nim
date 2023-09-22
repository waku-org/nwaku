{.used.}

import
  std/[sequtils,tempfiles],
  stew/byteutils,
  stew/shims/net,
  testutils/unittests,
  presto, presto/client as presto_client,
  libp2p/crypto/crypto
import
  ../../waku/common/base64,
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/waku_api/message_cache,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/client,
  ../../waku/waku_api/rest/responses,
  ../../waku/waku_api/rest/relay/types,
  ../../waku/waku_api/rest/relay/handlers as relay_api,
  ../../waku/waku_api/rest/relay/client as relay_api_client,
  ../../waku/waku_relay,
  ../../../waku/waku_rln_relay,
  ../testlib/wakucore,
  ../testlib/wakunode

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))


suite "Waku v2 Rest API - Relay":
  asyncTest "Subscribe a node to an array of pubsub topics - POST /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58011)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let cache = MessageCache[string].init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let pubSubTopics = @[
      PubSubTopic("pubsub-topic-1"),
      PubSubTopic("pubsub-topic-2"),
      PubSubTopic("pubsub-topic-3")
    ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let requestBody = RelayPostSubscriptionsRequest(pubSubTopics)
    let response = await client.relayPostSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      cache.isSubscribed("pubsub-topic-1")
      cache.isSubscribed("pubsub-topic-2")
      cache.isSubscribed("pubsub-topic-3")

    check:
      toSeq(node.wakuRelay.subscribedTopics).len == pubSubTopics.len

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of pubsub topics - DELETE /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay(@[
      "pubsub-topic-1",
      "pubsub-topic-2",
      "pubsub-topic-3",
      "pubsub-topic-x",
      ])

    let restPort = Port(58012)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let cache = MessageCache[string].init()
    cache.subscribe("pubsub-topic-1")
    cache.subscribe("pubsub-topic-2")
    cache.subscribe("pubsub-topic-3")
    cache.subscribe("pubsub-topic-x")

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let pubSubTopics = @[
      PubSubTopic("pubsub-topic-1"),
      PubSubTopic("pubsub-topic-2"),
      PubSubTopic("pubsub-topic-3"),
      PubSubTopic("pubsub-topic-y")
    ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let requestBody = RelayDeleteSubscriptionsRequest(pubSubTopics)
    let response = await client.relayDeleteSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not cache.isSubscribed("pubsub-topic-1")
      not node.wakuRelay.isSubscribed("pubsub-topic-1")
      not cache.isSubscribed("pubsub-topic-2")
      not node.wakuRelay.isSubscribed("pubsub-topic-2")
      not cache.isSubscribed("pubsub-topic-3")
      not node.wakuRelay.isSubscribed("pubsub-topic-3")
      cache.isSubscribed("pubsub-topic-x")
      node.wakuRelay.isSubscribed("pubsub-topic-x")
      not cache.isSubscribed("pubsub-topic-y")
      not node.wakuRelay.isSubscribed("pubsub-topic-y")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Get the latest messages for a pubsub topic - GET /relay/v1/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58013)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let pubSubTopic = "/waku/2/default-waku/proto"
    let messages =  @[
      fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1")),
      fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1")),
      fakeWakuMessage(contentTopic = "content-topic-x", payload = toBytes("TEST-1")),
    ]

    let cache = MessageCache[string].init()

    cache.subscribe(pubSubTopic)
    for msg in messages:
      cache.addMessage(pubSubTopic, msg)

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayGetMessagesV1(pubSubTopic)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.len == 3
      response.data.all do (msg: RelayWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
        msg.contentTopic.get() == "content-topic-x" and
        msg.version.get() == 2 and
        msg.timestamp.get() != Timestamp(0)


    check:
      cache.isSubscribed(pubSubTopic)
      cache.getMessages(pubSubTopic).tryGet().len == 0

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to a pubsub topic - POST /relay/v1/messages/{topic}":
    ## "Relay API: publish and subscribe/unsubscribe":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()
    await node.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1")))

    # RPC server setup
    let restPort = Port(58014)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let cache = MessageCache[string].init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic))
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostMessagesV1(DefaultPubsubTopic, RelayWakuMessage(
      payload: base64.encode("TEST-PAYLOAD"),
      contentTopic: some(DefaultContentTopic),
      timestamp: some(int64(2022))
    ))

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  # Autosharding API

  asyncTest "Subscribe a node to an array of content topics - POST /relay/v1/auto/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58011)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let cache = MessageCache[string].init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let contentTopics = @[
      ContentTopic("/waku/2/default-content1/proto"),
      ContentTopic("/waku/2/default-content2/proto"),
      ContentTopic("/waku/2/default-content3/proto")
    ]

    let shards = contentTopics.mapIt(getShard(it).expect("Valid Shard")).deduplicate()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let requestBody = RelayPostSubscriptionsRequest(contentTopics)
    let response = await client.relayPostAutoSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      cache.isSubscribed(contentTopics[0])
      cache.isSubscribed(contentTopics[1])
      cache.isSubscribed(contentTopics[2])

    check:
      # Node should be subscribed to all shards
      toSeq(node.wakuRelay.subscribedTopics).len == shards.len

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of content topics - DELETE /relay/v1/auto/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58012)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let contentTopics = @[
      ContentTopic("/waku/2/default-content1/proto"),
      ContentTopic("/waku/2/default-content2/proto"),
      ContentTopic("/waku/2/default-content3/proto"),
      ContentTopic("/waku/2/default-contentX/proto")
    ]

    let cache = MessageCache[string].init()
    cache.subscribe(contentTopics[0])
    cache.subscribe(contentTopics[1])
    cache.subscribe(contentTopics[2])
    cache.subscribe("/waku/2/default-contentY/proto")

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let requestBody = RelayDeleteSubscriptionsRequest(contentTopics)
    let response = await client.relayDeleteAutoSubscriptionsV1(requestBody)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not cache.isSubscribed(contentTopics[1])
      not cache.isSubscribed(contentTopics[2])
      not cache.isSubscribed(contentTopics[3])
      cache.isSubscribed("/waku/2/default-contentY/proto")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Get the latest messages for a content topic - GET /relay/v1/auto/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58013)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let contentTopic = DefaultContentTopic
    let messages =  @[
      fakeWakuMessage(contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")),
      fakeWakuMessage(contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")),
      fakeWakuMessage(contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")),
    ]

    let cache = MessageCache[string].init()

    cache.subscribe(contentTopic)
    for msg in messages:
      cache.addMessage(contentTopic, msg)

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayGetAutoMessagesV1(contentTopic)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.len == 3
      response.data.all do (msg: RelayWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
        msg.contentTopic.get() == DefaultContentTopic and
        msg.version.get() == 2 and
        msg.timestamp.get() != Timestamp(0)

    check:
      cache.isSubscribed(contentTopic)
      cache.getMessages(contentTopic).tryGet().len == 0 # The cache is cleared when getMessage is called

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to a content topic - POST /relay/v1/auto/messages/{topic}":
    ## "Relay API: publish and subscribe/unsubscribe":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()
    await node.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1")))

    # RPC server setup
    let restPort = Port(58014)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let cache = MessageCache[string].init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    node.subscribe((kind: ContentSub, topic: DefaultContentTopic))
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostAutoMessagesV1(DefaultContentTopic, RelayWakuMessage(
      payload: base64.encode("TEST-PAYLOAD"),
      contentTopic: some(DefaultContentTopic),
      timestamp: some(int64(2022))
    ))

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()