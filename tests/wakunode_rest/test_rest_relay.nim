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
  ../../waku/node/rest/server,
  ../../waku/node/rest/client,
  ../../waku/node/rest/responses,
  ../../waku/node/rest/relay/types,
  ../../waku/node/rest/relay/handlers as relay_api,
  ../../waku/node/rest/relay/client as relay_api_client,
  ../../waku/node/rest/relay/topic_cache,
  ../../waku/waku_relay,
  ../testlib/wakucore,
  ../testlib/wakunode

when defined(rln):
  import
    ../../../waku/waku_rln_relay

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))


suite "Waku v2 Rest API - Relay":
  asyncTest "Subscribe a node to an array of topics - POST /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58011)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let topicCache = TopicCache.init()

    installRelayPostSubscriptionsV1Handler(restServer.router, node, topicCache)
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
      topicCache.isSubscribed("pubsub-topic-1")
      topicCache.isSubscribed("pubsub-topic-2")
      topicCache.isSubscribed("pubsub-topic-3")

    check:
      # Node should be subscribed to default + new topics
      toSeq(node.wakuRelay.subscribedTopics).len == pubSubTopics.len

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of topics - DELETE /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    let restPort = Port(58012)
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
      $response.contentType == $MIMETYPE_JSON
      response.data.len == 3
      response.data.all do (msg: RelayWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
        msg.contentTopic.get().string == "content-topic-x" and
        msg.version.get() == 2 and
        msg.timestamp.get() != Timestamp(0)


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
    await node.mountRelay()
    when defined(rln):
      await node.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
          rlnRelayCredIndex: 1,
          rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1")))

    # RPC server setup
    let restPort = Port(58014)
    let restAddress = ValidIpAddress.init("0.0.0.0")
    let restServer = RestServerRef.init(restAddress, restPort).tryGet()

    let topicCache = TopicCache.init()

    installRelayApiHandlers(restServer.router, node, topicCache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    node.subscribe(DefaultPubsubTopic)
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1


    # When
    let newTopics = @[
      PubSubTopic("pubsub-topic-1"),
      PubSubTopic("pubsub-topic-2"),
      PubSubTopic("pubsub-topic-3")
    ]
    discard await client.relayPostSubscriptionsV1(newTopics)

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

    # TODO: Check for the message to be published to the topic

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
