{.used.}

import
  std/[sequtils, strformat, tempfiles],
  stew/byteutils,
  stew/shims/net,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto
import
  waku/[
    common/base64,
    waku_core,
    waku_node,
    waku_api/message_cache,
    waku_api/rest/server,
    waku_api/rest/client,
    waku_api/rest/responses,
    waku_api/rest/relay/types,
    waku_api/rest/relay/handlers as relay_api,
    waku_api/rest/relay/client as relay_api_client,
    waku_relay,
    waku_rln_relay,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../resources/payloads

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

suite "Waku v2 Rest API - Relay":
  asyncTest "Subscribe a node to an array of pubsub topics - POST /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let pubSubTopics =
      @[
        PubSubTopic("pubsub-topic-1"),
        PubSubTopic("pubsub-topic-2"),
        PubSubTopic("pubsub-topic-3"),
      ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayPostSubscriptionsV1(pubSubTopics)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      cache.isPubsubSubscribed("pubsub-topic-1")
      cache.isPubsubSubscribed("pubsub-topic-2")
      cache.isPubsubSubscribed("pubsub-topic-3")

    check:
      toSeq(node.wakuRelay.subscribedTopics).len == pubSubTopics.len

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of pubsub topics - DELETE /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay(
      @["pubsub-topic-1", "pubsub-topic-2", "pubsub-topic-3", "pubsub-topic-x"]
    )

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()
    cache.pubsubSubscribe("pubsub-topic-1")
    cache.pubsubSubscribe("pubsub-topic-2")
    cache.pubsubSubscribe("pubsub-topic-3")
    cache.pubsubSubscribe("pubsub-topic-x")

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let pubSubTopics =
      @[
        PubSubTopic("pubsub-topic-1"),
        PubSubTopic("pubsub-topic-2"),
        PubSubTopic("pubsub-topic-3"),
        PubSubTopic("pubsub-topic-y"),
      ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayDeleteSubscriptionsV1(pubSubTopics)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not cache.isPubsubSubscribed("pubsub-topic-1")
      not node.wakuRelay.isSubscribed("pubsub-topic-1")
      not cache.isPubsubSubscribed("pubsub-topic-2")
      not node.wakuRelay.isSubscribed("pubsub-topic-2")
      not cache.isPubsubSubscribed("pubsub-topic-3")
      not node.wakuRelay.isSubscribed("pubsub-topic-3")
      cache.isPubsubSubscribed("pubsub-topic-x")
      node.wakuRelay.isSubscribed("pubsub-topic-x")
      not cache.isPubsubSubscribed("pubsub-topic-y")
      not node.wakuRelay.isSubscribed("pubsub-topic-y")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Get the latest messages for a pubsub topic - GET /relay/v1/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let pubSubTopic = "/waku/2/rs/0/0"

    var messages =
      @[
        fakeWakuMessage(
          contentTopic = "content-topic-x",
          payload = toBytes("TEST-1"),
          meta = toBytes("test-meta"),
          ephemeral = true,
        )
      ]

    # Prevent duplicate messages
    for i in 0 ..< 2:
      var msg = fakeWakuMessage(
        contentTopic = "content-topic-x",
        payload = toBytes("TEST-1"),
        meta = toBytes("test-meta"),
        ephemeral = true,
      )

      while msg == messages[i]:
        msg = fakeWakuMessage(
          contentTopic = "content-topic-x",
          payload = toBytes("TEST-1"),
          meta = toBytes("test-meta"),
          ephemeral = true,
        )

      messages.add(msg)

    let cache = MessageCache.init()

    cache.pubsubSubscribe(pubSubTopic)
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
      response.data.all do(msg: RelayWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
          msg.contentTopic.get() == "content-topic-x" and msg.version.get() == 2 and
          msg.timestamp.get() != Timestamp(0) and
          msg.meta.get() == base64.encode("test-meta") and msg.ephemeral.get() == true

    check:
      cache.isPubsubSubscribed(pubSubTopic)
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
    let wakuRlnConfig = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(1.uint),
      rlnRelayUserMessageLimit: 20,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1"),
    )

    await node.mountRlnRelay(wakuRlnConfig)

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic))
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: some(DefaultContentTopic),
        timestamp: some(int64(2022)),
      ),
    )

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
    require node.mountSharding(1, 8).isOk

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let contentTopics =
      @[
        ContentTopic("/app-1/2/default-content/proto"),
        ContentTopic("/app-2/2/default-content/proto"),
        ContentTopic("/app-3/2/default-content/proto"),
      ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayPostAutoSubscriptionsV1(contentTopics)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      cache.isContentSubscribed(contentTopics[0])
      cache.isContentSubscribed(contentTopics[1])
      cache.isContentSubscribed(contentTopics[2])

    check:
      # Node should be subscribed to all shards
      node.wakuRelay.subscribedTopics ==
        @["/waku/2/rs/1/7", "/waku/2/rs/1/2", "/waku/2/rs/1/5"]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of content topics - DELETE /relay/v1/auto/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let contentTopics =
      @[
        ContentTopic("/waku/2/default-content1/proto"),
        ContentTopic("/waku/2/default-content2/proto"),
        ContentTopic("/waku/2/default-content3/proto"),
        ContentTopic("/waku/2/default-contentX/proto"),
      ]

    let cache = MessageCache.init()
    cache.contentSubscribe(contentTopics[0])
    cache.contentSubscribe(contentTopics[1])
    cache.contentSubscribe(contentTopics[2])
    cache.contentSubscribe("/waku/2/default-contentY/proto")

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayDeleteAutoSubscriptionsV1(contentTopics)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not cache.isContentSubscribed(contentTopics[1])
      not cache.isContentSubscribed(contentTopics[2])
      not cache.isContentSubscribed(contentTopics[3])
      cache.isContentSubscribed("/waku/2/default-contentY/proto")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Get the latest messages for a content topic - GET /relay/v1/auto/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let contentTopic = DefaultContentTopic

    var messages =
      @[
        fakeWakuMessage(contentTopic = DefaultContentTopic, payload = toBytes("TEST-1"))
      ]

    # Prevent duplicate messages
    for i in 0 ..< 2:
      var msg =
        fakeWakuMessage(contentTopic = DefaultContentTopic, payload = toBytes("TEST-1"))

      while msg == messages[i]:
        msg = fakeWakuMessage(
          contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
        )

      messages.add(msg)

    let cache = MessageCache.init()

    cache.contentSubscribe(contentTopic)
    for msg in messages:
      cache.addMessage(DefaultPubsubTopic, msg)

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
      response.data.all do(msg: RelayWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
          msg.contentTopic.get() == DefaultContentTopic and msg.version.get() == 2 and
          msg.timestamp.get() != Timestamp(0)

    check:
      cache.isContentSubscribed(contentTopic)
      cache.getAutoMessages(contentTopic).tryGet().len == 0
        # The cache is cleared when getMessage is called

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to a content topic - POST /relay/v1/auto/messages/{topic}":
    ## "Relay API: publish and subscribe/unsubscribe":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()
    let wakuRlnConfig = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(1.uint),
      rlnRelayUserMessageLimit: 20,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1"),
    )

    await node.mountRlnRelay(wakuRlnConfig)

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    node.subscribe((kind: ContentSub, topic: DefaultContentTopic))
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: some(DefaultContentTopic),
        timestamp: some(int64(2022)),
      )
    )

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to an invalid content topic - POST /relay/v1/auto/messages/{topic}":
    ## "Relay API: publish and subscribe/unsubscribe":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()
    let wakuRlnConfig = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(1.uint),
      rlnRelayUserMessageLimit: 20,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1"),
    )

    await node.mountRlnRelay(wakuRlnConfig)

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let invalidContentTopic = "invalidContentTopic"
    # When
    let response = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: some(invalidContentTopic),
        timestamp: some(int64(2022)),
      )
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data ==
        "Failed to publish. Autosharding error: invalid format: content-topic '" &
        invalidContentTopic & "' must start with slash"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message larger than maximum size - POST /relay/v1/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()
    let wakuRlnConfig = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(1.uint),
      rlnRelayUserMessageLimit: 20,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1"),
    )

    await node.mountRlnRelay(wakuRlnConfig)

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic))
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode(getByteSequence(DefaultMaxWakuMessageSize)),
          # Message will be bigger than the max size
        contentTopic: some(DefaultContentTopic),
        timestamp: some(int64(2022)),
      ),
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data ==
        fmt"Failed to publish: Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message larger than maximum size - POST /relay/v1/auto/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    await node.mountRelay()
    let wakuRlnConfig = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(1.uint),
      rlnRelayUserMessageLimit: 20,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_1"),
    )

    await node.mountRlnRelay(wakuRlnConfig)

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic))
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode(getByteSequence(DefaultMaxWakuMessageSize)),
          # Message will be bigger than the max size
        contentTopic: some(DefaultContentTopic),
        timestamp: some(int64(2022)),
      )
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data ==
        fmt"Failed to publish: Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
