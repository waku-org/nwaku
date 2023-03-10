{.used.}

import
  std/[options,tables],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/peerstore
import
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/protocol/waku_filter_v2,
  ../../../waku/v2/protocol/waku_filter_v2/client,
  ../../../waku/v2/protocol/waku_filter_v2/rpc,
  ../../../waku/v2/protocol/waku_message,
  ../testlib/common,
  ../testlib/waku2

proc newTestWakuFilter(switch: Switch): Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuFilterClient(switch: Switch, messagePushHandler: MessagePushHandler): Future[WakuFilterClient] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilterClient.new(rng, messagePushHandler, peerManager)

  await proto.start()
  switch.mount(proto)

  return proto

suite "Waku Filter - end to end":

  asyncTest "ping":
    # Given
    var
      voidHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
        discard
    let
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch, voidHandler)

    # When
    await allFutures(serverSwitch.start(), clientSwitch.start())
    let response = await wakuFilterClient.ping(serverSwitch.peerInfo.toRemotePeerInfo())

    # Then
    check:
      response.isErr() # Not subscribed
      response.error().kind == FilterSubscribeErrorKind.NOT_FOUND

    # When
    let response2 = await wakuFilterClient.subscribe(serverSwitch.peerInfo.toRemotePeerInfo(), DefaultPubsubTopic, @[DefaultContentTopic])

    require response2.isOk()

    let response3 = await wakuFilterClient.ping(serverSwitch.peerInfo.toRemotePeerInfo())

    # Then
    check:
      response3.isOk() # Subscribed

    # Teardown
    await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())

  asyncTest "simple subscribe and unsubscribe request":
    # Given
    var
      pushHandlerFuture = newFuture[(string, WakuMessage)]()
      messagePushHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
        pushHandlerFuture.complete((pubsubTopic, message))

    let
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch, messagePushHandler)
      clientPeerId = clientSwitch.peerInfo.peerId
      pubsubTopic = DefaultPubsubTopic
      contentTopics = @[DefaultContentTopic]

    # When
    await allFutures(serverSwitch.start(), clientSwitch.start())
    let response = await wakuFilterClient.subscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic, contentTopics)

    # Then
    check:
      response.isOk()
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions.hasKey(clientPeerId)

    # When
    let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg1)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == DefaultPubsubTopic
      pushedMsg == msg1

    # When
    let response2 = await wakuFilterClient.unsubscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic, contentTopics)

    # Then
    check:
      response2.isOk()
      wakuFilter.subscriptions.len == 0

    # When
    let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg2)

    # Then
    check:
      not (await pushHandlerFuture.withTimeout(2.seconds)) # No message should be pushed

    # Teardown
    await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())

  asyncTest "subscribe, unsubscribe multiple content topics":
    # Given
    var
      pushHandlerFuture = newFuture[(string, WakuMessage)]()
      messagePushHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
        pushHandlerFuture.complete((pubsubTopic, message))

    let
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch, messagePushHandler)
      clientPeerId = clientSwitch.peerInfo.peerId
      pubsubTopic = DefaultPubsubTopic
      contentTopic2 = ContentTopic("/waku/2/non-default-content/proto")
      contentTopics = @[DefaultContentTopic, contentTopic2]

    # When
    await allFutures(serverSwitch.start(), clientSwitch.start())
    let response = await wakuFilterClient.subscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic, contentTopics)

    # Then
    check:
      response.isOk()
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions.hasKey(clientPeerId)

    # When
    let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg1)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == DefaultPubsubTopic
      pushedMsg == msg1

    # When
    let msg2 = fakeWakuMessage(contentTopic=contentTopic2)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg2)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic2 == DefaultPubsubTopic
      pushedMsg2 == msg2

    # When
    let response2 = await wakuFilterClient.unsubscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic, @[contentTopic2]) # Unsubscribe only one content topic

    # Then
    check:
      response2.isOk()
      wakuFilter.subscriptions.len == 1

    # When
    let msg3 = fakeWakuMessage(contentTopic=DefaultContentTopic)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg3)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic3 == DefaultPubsubTopic
      pushedMsg3 == msg3

    # When
    let msg4 = fakeWakuMessage(contentTopic=contentTopic2)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg4)

    # Then
    check:
      not (await pushHandlerFuture.withTimeout(2.seconds)) # No message should be pushed

  asyncTest "subscribe to multiple content topics and unsubscribe all":
    # Given
    var
      pushHandlerFuture = newFuture[(string, WakuMessage)]()
      messagePushHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
        pushHandlerFuture.complete((pubsubTopic, message))

    let
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch, messagePushHandler)
      clientPeerId = clientSwitch.peerInfo.peerId
      pubsubTopic = DefaultPubsubTopic
      contentTopic2 = ContentTopic("/waku/2/non-default-content/proto")
      contentTopics = @[DefaultContentTopic, contentTopic2]

    # When
    await allFutures(serverSwitch.start(), clientSwitch.start())
    let response = await wakuFilterClient.subscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic, contentTopics)

    # Then
    check:
      response.isOk()
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions.hasKey(clientPeerId)

    # When
    let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg1)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == DefaultPubsubTopic
      pushedMsg == msg1

    # When
    let msg2 = fakeWakuMessage(contentTopic=contentTopic2)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg2)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic2 == DefaultPubsubTopic
      pushedMsg2 == msg2

    # When
    let response2 = await wakuFilterClient.unsubscribeAll(serverSwitch.peerInfo.toRemotePeerInfo())

    # Then
    check:
      response2.isOk()
      wakuFilter.subscriptions.len == 0

    # When
    let
      msg3 = fakeWakuMessage(contentTopic=DefaultContentTopic)
      msg4 = fakeWakuMessage(contentTopic=contentTopic2)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg3)
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg4)

    # Then
    check:
      not (await pushHandlerFuture.withTimeout(2.seconds)) # Neither message should be pushed

    # Teardown
    await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())

  asyncTest "subscribe, unsubscribe multiple pubsub topics and content topics":
    # Given
    var
      pushHandlerFuture = newFuture[(string, WakuMessage)]()
      messagePushHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
        pushHandlerFuture.complete((pubsubTopic, message))

    let
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch, messagePushHandler)
      clientPeerId = clientSwitch.peerInfo.peerId
      pubsubTopic = DefaultPubsubTopic
      pubsubTopic2 = PubsubTopic("/waku/2/non-default-pubsub/proto")
      contentTopic2 = ContentTopic("/waku/2/non-default-content/proto")
      contentTopics = @[DefaultContentTopic, contentTopic2]

    ## Step 1: We can subscribe to multiple pubsub topics and content topics

    # When
    await allFutures(serverSwitch.start(), clientSwitch.start())
    let
      response1 = await wakuFilterClient.subscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic, contentTopics)
      response2 = await wakuFilterClient.subscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic2, contentTopics)

    # Then
    check:
      response1.isOk()
      response2.isOk()
      wakuFilter.subscriptions.len == 1
      wakuFilter.subscriptions.hasKey(clientPeerId)

    ## Step 2: We receive messages for multiple subscribed pubsub topics and content topics

    # When
    let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg1)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == DefaultPubsubTopic
      pushedMsg == msg1

    # When
    let msg2 = fakeWakuMessage(contentTopic=contentTopic2)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(pubsubTopic2, msg2)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic2 == pubsubTopic2
      pushedMsg2 == msg2

    ## Step 3: We can selectively unsubscribe from pubsub topics and content topic(s)

    # When
    let response3 = await wakuFilterClient.unsubscribe(serverSwitch.peerInfo.toRemotePeerInfo(), pubsubTopic2, @[contentTopic2])
    require response3.isOk()

    let msg3 = fakeWakuMessage(contentTopic=contentTopic2)
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(pubsubTopic2, msg3)

    # Then
    check:
      not (await pushHandlerFuture.withTimeout(2.seconds)) # No message should be pushed

    ## Step 4: We can still receive messages for other subscribed pubsub topics and content topics

    # When
    pushHandlerFuture = newFuture[(string, WakuMessage)]() # Clear previous future
    await wakuFilter.handleMessage(DefaultPubsubTopic, msg3)

    require await pushHandlerFuture.withTimeout(3.seconds)

    # Then
    let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic3 == DefaultPubsubTopic
      pushedMsg3 == msg3
