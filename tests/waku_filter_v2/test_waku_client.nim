{.used.}

import
  std/[
    options, 
    tables, 
    sequtils, 
    strutils, 
    json
  ],
  testutils/unittests,
  stew/[
    results, 
    byteutils
  ],
  chronos,
  chronicles,
  os,
  libp2p/peerstore

import
  ../../../waku/[
    node/peer_manager,
    waku_core
  ],
  ../../../waku/waku_filter_v2/[
    common,
    client,
    subscriptions,
    protocol
  ],
  ../testlib/[
    wakucore,
    testasync,
    testutils,
    futures,
    sequtils
  ],
  ./waku_filter_utils,
  ../resources/payloads


suite "Waku Filter - End to End":
  suite "MessagePushHandler - Void":
    var serverSwitch {.threadvar.}: Switch
    var clientSwitch {.threadvar.}: Switch
    var wakuFilter {.threadvar.}: WakuFilter
    var wakuFilterClient {.threadvar.}: WakuFilterClient
    var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    var pubsubTopic {.threadvar.}: PubsubTopic
    var contentTopic {.threadvar.}: ContentTopic
    var contentTopicSeq {.threadvar.}: seq[ContentTopic]
    var clientPeerId {.threadvar.}: PeerId
    var messagePushHandler {.threadvar.}: FilterPushHandler
    var msgSeq {.threadvar.}: seq[(PubsubTopic, WakuMessage)]
    var pushHandlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]

    asyncSetup:
      msgSeq = @[]
      pushHandlerFuture = newPushHandlerFuture()
      messagePushHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[void] {.async, closure, gcsafe.} =
        msgSeq.add((pubsubTopic, message))
        pushHandlerFuture.complete((pubsubTopic, message))

      pubsubTopic = DefaultPubsubTopic
      contentTopic = DefaultContentTopic
      contentTopicSeq = @[contentTopic]
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch)

      await allFutures(serverSwitch.start(), clientSwitch.start())
      wakuFilterClient.registerPushHandler(messagePushHandler)
      serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
      clientPeerId = clientSwitch.peerInfo.toRemotePeerInfo().peerId
      
    asyncTeardown:
      await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())

    suite "Subscriber Ping":
      asyncTest "Active Subscription Identification":
        # Given
        let 
          subscribeResponse = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, contentTopicSeq
          )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check wakuFilter.subscriptions.hasKey(clientPeerId)

        # When
        let subscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

        # Then
        assert subscribedPingResponse.isOk(), $subscribedPingResponse.error
        check:
          wakuFilter.subscriptions.hasKey(clientPeerId)

      asyncTest "No Active Subscription Identification":
        # When
        let unsubscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

        # Then
        check:
          unsubscribedPingResponse.isErr() # Not subscribed
          unsubscribedPingResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

      asyncTest "After Unsubscription":
        # Given
        let 
          subscribeResponse = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, contentTopicSeq
          )

        assert subscribeResponse.isOk(), $subscribeResponse.error
        check wakuFilter.subscriptions.hasKey(clientPeerId)

        # When
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check not wakuFilter.subscriptions.hasKey(clientPeerId)

        let unsubscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

        # Then
        check:
          unsubscribedPingResponse.isErr() # Not subscribed
          unsubscribedPingResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

    suite "Subscribe":
      asyncTest "Server remote peer info doesn't match an online server":
        # Given an offline service node
        let offlineServerSwitch = newStandardSwitch()
        let offlineServerRemotePeerInfo = offlineServerSwitch.peerInfo.toRemotePeerInfo()

        # When subscribing to the offline service node
        let subscribeResponse = await wakuFilterClient.subscribe(
          offlineServerRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is not successful
        check:
          subscribeResponse.isErr() # Not subscribed
          subscribeResponse.error().kind == FilterSubscribeErrorKind.PEER_DIAL_FAILURE

      asyncTest "Subscribing to an empty content topic":
        # When subscribing to an empty content topic
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, @[]
        )

        # Then the subscription is not successful
        check:
          subscribeResponse.isErr() # Not subscribed
          subscribeResponse.error().kind == FilterSubscribeErrorKind.BAD_REQUEST

      asyncTest "PubSub Topic with Single Content Topic":
        # Given
        let nonExistentContentTopic = "non-existent-content-topic"

        # When subscribing to a content topic
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is successful
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When sending a message to the subscribed content topic
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic == pubsubTopic
          pushedMsg == msg1
        
        # When sending a message to a non-subscribed content topic (before unsubscription)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=nonExistentContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

        # Given a valid unsubscription to an existing subscription
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0

        # When sending a message to the previously unsubscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg3 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg3)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        
        # When sending a message to a non-subscribed content topic (after unsubscription)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg4 = fakeWakuMessage(contentTopic=nonExistentContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg4)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      asyncTest "PubSub Topic with Multiple Content Topics":
        # Given
        let nonExistentContentTopic = "non-existent-content-topic"
        let otherContentTopic = "other-content-topic"
        let contentTopicsSeq = @[contentTopic, otherContentTopic]

        # Given a valid subscription to multiple content topics
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicsSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicsSeq

        # When sending a message to the one of the subscribed content topics
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1
        
        # When sending a message to the other subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2
        
        # When sending a message to a non-subscribed content topic (before unsubscription)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg3 = fakeWakuMessage(contentTopic=nonExistentContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg3)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        
        # Given a valid unsubscription to an existing subscription
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicsSeq
        )
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check wakuFilter.subscriptions.len == 0
        
        # When sending a message to the previously unsubscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg4 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg4)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

        # When sending a message to the other previously unsubscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg5 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg5)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        
        # When sending a message to a non-subscribed content topic (after unsubscription)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg6 = fakeWakuMessage(contentTopic=nonExistentContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg6)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      asyncTest "Different PubSub Topics with Different Content Topics, Unsubscribe One By One":
        # Given
        let otherPubsubTopic = "other-pubsub-topic"
        let otherContentTopic = "other-content-topic"
        let otherContentTopicSeq = @[otherContentTopic]

        # When subscribing to a pubsub topic
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq 
        )

        # Then the subscription is successful
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When subscribing to a different pubsub topic
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, otherPubsubTopic, otherContentTopicSeq
        )

        # Then the subscription is successful
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq & otherContentTopicSeq

        # When sending a message to one of the subscribed content topics
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1
        
        # When sending a message to the other subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == otherPubsubTopic
          pushedMsg2 == msg2

        # When sending a message to a non-subscribed content topic (before unsubscription)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg3 = fakeWakuMessage(contentTopic="non-existent-content-topic")
        await wakuFilter.handleMessage(pubsubTopic, msg3)

        # Then
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == otherContentTopicSeq
        
        # When sending a message to the previously subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg4 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg4)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        
        # When sending a message to the still subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg5 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg5)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == otherPubsubTopic
          pushedMsg3 == msg5
        
        # When unsubscribing from the other subscription
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, otherPubsubTopic, otherContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 0

        # When sending a message to the previously unsubscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg6 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg6)

        # Then the message is not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      asyncTest "Different PubSub Topics with Different Content Topics, Unsubscribe All":
        # Given
        let otherPubsubTopic = "other-pubsub-topic"
        let otherContentTopic = "other-content-topic"
        let otherContentTopicSeq = @[otherContentTopic]

        # When subscribing to a content topic
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When subscribing to a different content topic
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, otherPubsubTopic, otherContentTopicSeq
        )

        # Then
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq & otherContentTopicSeq

        # When sending a message to one of the subscribed content topics
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1
        
        # When sending a message to the other subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == otherPubsubTopic
          pushedMsg2 == msg2

        # When sending a message to a non-subscribed content topic (before unsubscription)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg3 = fakeWakuMessage(contentTopic="non-existent-content-topic")
        await wakuFilter.handleMessage(pubsubTopic, msg3)

        # Then
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse = await wakuFilterClient.unsubscribeAll(serverRemotePeerInfo)

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0
        
        # When sending a message the previously subscribed content topics
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg4 = fakeWakuMessage(contentTopic=contentTopic)
        let msg5 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg4)
        await wakuFilter.handleMessage(otherPubsubTopic, msg5)

        # Then the messages are not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      asyncTest "Different PubSub Topics with Same Content Topics, Unsubscribe Selectively":
        # Given
        let otherPubsubTopic = "other-pubsub-topic"
        let otherContentTopic1 = "other-content-topic1"
        let otherContentTopic2 = "other-content-topic2"
        let contentTopicsSeq1 = @[contentTopic, otherContentTopic1]
        let contentTopicsSeq2 = @[contentTopic, otherContentTopic2]

        # When subscribing to a pubsub topic
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicsSeq1 
        )

        # Then the subscription is successful
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicsSeq1

        # When subscribing to a different pubsub topic
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, otherPubsubTopic, contentTopicsSeq2
        )

        # Then the subscription is successful
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicsSeq1 & contentTopicsSeq2

        # When sending a message to (pubsubTopic, contentTopic)
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # When sending a message to (pubsubTopic, otherContentTopic1)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic1)
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2
        
        # When sending a message to (otherPubsubTopic, contentTopic)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg3 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg3)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == otherPubsubTopic
          pushedMsg3 == msg3
        
        # When sending a message to (otherPubsubTopic, otherContentTopic2)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg4 = fakeWakuMessage(contentTopic=otherContentTopic2)
        await wakuFilter.handleMessage(otherPubsubTopic, msg4)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic4, pushedMsg4) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic4 == otherPubsubTopic
          pushedMsg4 == msg4
        
        # When selectively unsubscribing from (pubsubTopic, otherContentTopic1) and (otherPubsubTopic, contentTopic)
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[otherContentTopic1]
        )
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, otherPubsubTopic, @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == @[contentTopic, otherContentTopic2]

        # When sending a message to (pubsubTopic, contentTopic)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg5 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg5)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic5, pushedMsg5) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic5 == pubsubTopic
          pushedMsg5 == msg5

        # When sending a message to (otherPubsubTopic, otherContentTopic2)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg6 = fakeWakuMessage(contentTopic=otherContentTopic2)
        await wakuFilter.handleMessage(otherPubsubTopic, msg6)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic6, pushedMsg6) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic6 == otherPubsubTopic
          pushedMsg6 == msg6
        
        # When sending a message to (pubsubTopic, otherContentTopic1) and (otherPubsubTopic, contentTopic)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg7 = fakeWakuMessage(contentTopic=otherContentTopic1)
        await wakuFilter.handleMessage(pubsubTopic, msg7)
        let msg8 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg8)

        # Then the messages are not pushed to the client
        check:
          not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      asyncTest "Max Topic Size":
        # Given a topic list of 30 topics
        var topicSeq: seq[string] = toSeq(0..<MaxContentTopicsPerRequest).mapIt("topic" & $it)

        # When subscribing to that topic list
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, topicSeq
        )

        # Then the subscription is successful
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 30

        # When refreshing the subscription with a topic list of 30 topics
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, topicSeq
        )

        # Then the subscription is successful
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 30

        # When creating a subscription with a topic list of 31 topics
        let subscribeResponse3 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, topicSeq & @["topic30"]
        )

        # Then the subscription is not successful
        check:
          subscribeResponse3.isErr() # Not subscribed
          subscribeResponse3.error().kind == FilterSubscribeErrorKind.BAD_REQUEST
        
        # And the previous subscription is still active
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 30

      asyncTest "Max Criteria Per Subscription":  
        # Given a topic list of size MaxCriteriaPerSubscription
        var topicSeq: seq[string] = toSeq(0..<MaxCriteriaPerSubscription).mapIt("topic" & $it)
      
        # When client service node subscribes to the topic list of size MaxCriteriaPerSubscription
        var subscribedTopics: seq[string] = @[]
        while topicSeq.len > 0:
          let takeNumber = min(topicSeq.len, MaxContentTopicsPerRequest)
          let topicSeqBatch = topicSeq[0..<takeNumber]
          let subscribeResponse = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, topicSeqBatch
          )
          assert subscribeResponse.isOk(), $subscribeResponse.error
          subscribedTopics.add(topicSeqBatch)
          topicSeq.delete(0..<takeNumber)
      
        # Then the subscription is successful
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 1000

        # When subscribing to a number of topics that exceeds MaxCriteriaPerSubscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, @["topic1000"]
        )

        # Then the subscription is not successful
        check:
          subscribeResponse.isErr() # Not subscribed
          subscribeResponse.error().kind == FilterSubscribeErrorKind.SERVICE_UNAVAILABLE

        # And the previous subscription is still active
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 1000

      # Takes a long while because it instances a lot of clients. 
      xasyncTest "Max Total Subscriptions":      
        # Given a WakuFilterClient list of size MaxTotalSubscriptions
        var clients: seq[(WakuFilterClient, Switch)] = @[]
        for i in 0..<MaxTotalSubscriptions:
          let standardSwitch = newStandardSwitch()
          let wakuFilterClient = await newTestWakuFilterClient(standardSwitch, messagePushHandler)
          clients.add((wakuFilterClient, standardSwitch))
        
        # When initialising all of them and subscribing them to the same service
        for (wakuFilterClient, standardSwitch) in clients:
          await standardSwitch.start()
          let subscribeResponse = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, contentTopicSeq
          )  
        assert subscribeResponse.isOk(), $subscribeResponse.error

        # Then the service node should have MaxTotalSubscriptions subscriptions
        check:
          wakuFilter.subscriptions.len == 1000
        
        # When initialising a new WakuFilterClient and subscribing it to the same service
        let standardSwitch = newStandardSwitch()
        let wakuFilterClient = await newTestWakuFilterClient(standardSwitch, messagePushHandler)
        await standardSwitch.start()
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is not successful
        check:
          subscribeResponse.isErr() # Not subscribed
          subscribeResponse.error().kind == FilterSubscribeErrorKind.SERVICE_UNAVAILABLE

      asyncTest "Multiple Subscriptions":
        # Given a second service node
        let serverSwitch2 = newStandardSwitch()
        let wakuFilter2 = await newTestWakuFilter(serverSwitch2)
        await allFutures(serverSwitch2.start())
        let serverRemotePeerInfo2 = serverSwitch2.peerInfo.toRemotePeerInfo()

        # And a subscription to the first service node
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When subscribing to the second service node
        let subscriptionResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo2, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is successful
        assert subscriptionResponse2.isOk(), $subscriptionResponse2.error
        check:
          wakuFilter2.subscriptions.len == 1
          wakuFilter2.subscriptions.hasKey(clientPeerId)
          wakuFilter2.getSubscribedContentTopics(clientPeerId) == contentTopicSeq
        
        # And the first service node is still subscribed
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When sending a message to the subscribed content topic on the first service node
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # When sending a message to the subscribed content topic on the second service node
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter2.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2

      asyncTest "Refreshing Subscription":
        # Given a valid subscription  
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq
        
        # When refreshing the subscription
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is successful
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When sending a message to the refreshed subscription
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # And the message is not duplicated
        check:
          msgSeq.len == 1
          msgSeq[0][0] == pubsubTopic
          msgSeq[0][1] == msg1

      asyncTest "Overlapping Topic Subscription":
        # Given a set of overlapping subscriptions
        let 
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, contentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
          )
          subscribeResponse3 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
          )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        assert subscribeResponse3.isOk(), $subscribeResponse3.error
        check:
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When sending a message to the overlapping subscription 1
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # And the message is not duplicated
        check:
          msgSeq.len == 1
          msgSeq[0][0] == pubsubTopic
          msgSeq[0][1] == msg1

        # When sending a message to the overlapping subscription 2
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)) # Check there're no duplicate messages
        pushHandlerFuture = newPushHandlerFuture() # Reset future due to timeout

        let msg2 = fakeWakuMessage(contentTopic="other-content-topic")
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2

        # And the message is not duplicated
        check:
          msgSeq.len == 2
          msgSeq[1][0] == pubsubTopic
          msgSeq[1][1] == msg2

        # When sending a message to the overlapping subscription 3
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)) # Check there're no duplicate messages
        pushHandlerFuture = newPushHandlerFuture() # Reset future due to timeout

        let msg3 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage("other-pubsub-topic", msg3)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == "other-pubsub-topic"
          pushedMsg3 == msg3

        # And the message is not duplicated
        check:
          msgSeq.len == 3
          msgSeq[2][0] == "other-pubsub-topic"
          msgSeq[2][1] == msg3

    suite "Unsubscribe":

      ###
      # One PubSub Topic
      ###

      asyncTest "PubSub Topic with Single Content Topic":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq
        
        # When unsubscribing from the subscription
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0
        
      asyncTest "After refreshing a subscription with Single Content Topic":
        # Given a valid subscription
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq
        
        # When refreshing the subscription
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is successful
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq
        
        # When unsubscribing from the subscription
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "PubSub Topic with Multiple Content Topics, One By One":
        # Given a valid subscription
        let multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # When unsubscribing from one of the content topics
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == @["other-content-topic"]
        
        # When unsubscribing from the other content topic
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0
      
      asyncTest "PubSub Topic with Multiple Content Topics, All At Once":
        # Given a valid subscription
        let multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # When unsubscribing from all content topics
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a complete subscription with Multiple Content Topics, One By One":
        # Given a valid subscription
        let multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # And a successful complete refresh of the subscription
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # When unsubscribing from one of the content topics
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == @["other-content-topic"]
        
        # When unsubscribing from the other content topic
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a complete subscription with Multiple Content Topics, All At Once":
        # Given a valid subscription
        let multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # And a successful complete refresh of the subscription
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # When unsubscribing from all content topics
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a partial subscription with Multiple Content Topics, One By One":
        # Given a valid subscription
        let multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # Unsubscribing from one content topic
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == @["other-content-topic"]

        # And a successful refresh of the partial subscription
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # When unsubscribing from one of the content topics
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == @["other-content-topic"]
        
        # When unsubscribing from the other content topic
        let unsubscribeResponse3 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse3.isOk(), $unsubscribeResponse3.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a partial subscription with Multiple Content Topics, All At Once":
        # Given a valid subscription
        let multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # Unsubscribing from one content topic
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == @["other-content-topic"]
        
        # And a successful refresh of the partial subscription
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == multipleContentTopicSeq
        
        # When unsubscribing from all content topics
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 0

      ###
      # Multiple PubSub Topics
      ###

      asyncTest "Different PubSub Topics with Single (Same) Content Topic":
        # Given two valid subscriptions with the same content topic
        let
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, contentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 1
        
        # When unsubscribing from the other subscription
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 0
        
      asyncTest "Different PubSub Topics with Multiple (Same) Content Topics, One By One":
        # Given two valid subscriptions with the same content topics
        let
          multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 3
        
        # When unsubscribing from another of the subscriptions
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from another of the subscriptions
        let unsubscribeResponse3 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse3.isOk(), $unsubscribeResponse3.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 1
        
        # When unsubscribing from the last subscription
        let unsubscribeResponse4 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse4.isOk(), $unsubscribeResponse4.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "Different PubSub Topics with Multiple (Same) Content Topics, All At Once":
        # Given two valid subscriptions with the same content topics
        let
          multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4

        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from the other subscription
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a complete subscription with different PubSub Topics and Single (Same) Content Topic":
        # Given two valid subscriptions with the same content topic
        let
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, contentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # And a successful complete refresh of the subscription
        let 
          subscribeResponse3 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, contentTopicSeq
          )
          subscribeResponse4 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
          )
        
        assert subscribeResponse3.isOk(), $subscribeResponse3.error
        assert subscribeResponse4.isOk(), $subscribeResponse4.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 1
        
        # When unsubscribing from the other subscription
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a complete subscription with different PubSub Topics and Multiple (Same) Content Topics, One By One":
        # Given two valid subscriptions with the same content topics
        let
          multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # And a successful complete refresh of the subscription
        let 
          subscribeResponse3 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse4 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse3.isOk(), $subscribeResponse3.error
        assert subscribeResponse4.isOk(), $subscribeResponse4.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 3
        
        # When unsubscribing from another of the subscriptions
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from another of the subscriptions
        let unsubscribeResponse3 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse3.isOk(), $unsubscribeResponse3.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 1
        
        # When unsubscribing from the last subscription
        let unsubscribeResponse4 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", @[contentTopic]
        )
      
        # Then the unsubscription is successful
        assert unsubscribeResponse4.isOk(), $unsubscribeResponse4.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a complete subscription with different PubSub Topics and Multiple (Same) Content Topics, All At Once":
        # Given two valid subscriptions with the same content topics
        let
          multipleContentTopicSeq = @[contentTopic, "other-content-topic"]
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # And a successful complete refresh of the subscription
        let 
          subscribeResponse3 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse4 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse3.isOk(), $subscribeResponse3.error
        assert subscribeResponse4.isOk(), $subscribeResponse4.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from the other subscription
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a partial subscription with different PubSub Topics and Multiple (Same) Content Topics, One By One":
        # Given two valid subscriptions with the same content topics
        let
          multipleContentTopicSeq = contentTopicSeq & @["other-content-topic"]
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # Unsubscribing from one of the content topics of each subscription
        let
          unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
            serverRemotePeerInfo, pubsubTopic, @[contentTopic]
          )
          unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
            serverRemotePeerInfo, "other-pubsub-topic", @["other-content-topic"]
          )
        
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # And a successful refresh of the partial subscription
        let 
          refreshSubscriptionResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          refreshSubscriptionResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert refreshSubscriptionResponse1.isOk(), $refreshSubscriptionResponse1.error
        assert refreshSubscriptionResponse2.isOk(), $refreshSubscriptionResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4

        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse3 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse3.isOk(), $unsubscribeResponse3.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 3
        
        # When unsubscribing from another of the subscriptions
        let unsubscribeResponse4 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse4.isOk(), $unsubscribeResponse4.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from another of the subscriptions
        let unsubscribeResponse5 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse5.isOk(), $unsubscribeResponse5.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 1
        
        # When unsubscribing from the last subscription
        let unsubscribeResponse6 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", @[contentTopic]
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse6.isOk(), $unsubscribeResponse6.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "After refreshing a partial subscription with different PubSub Topics and Multiple (Same) Content Topics, All At Once":
        # Given two valid subscriptions with the same content topics
        let
          multipleContentTopicSeq = contentTopicSeq & @["other-content-topic"]
          subscribeResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          subscribeResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # Unsubscribing from one of the content topics of each subscription
        let
          unsubscribeResponse1 = await wakuFilterClient.unsubscribe(
            serverRemotePeerInfo, pubsubTopic, @[contentTopic]
          )
          unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
            serverRemotePeerInfo, "other-pubsub-topic", @["other-content-topic"]
          )
        
        assert unsubscribeResponse1.isOk(), $unsubscribeResponse1.error
        assert unsubscribeResponse2.isOk(), $unsubscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # And a successful refresh of the partial subscription
        let 
          refreshSubscriptionResponse1 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
          )
          refreshSubscriptionResponse2 = await wakuFilterClient.subscribe(
            serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
          )
        
        assert refreshSubscriptionResponse1.isOk(), $refreshSubscriptionResponse1.error
        assert refreshSubscriptionResponse2.isOk(), $refreshSubscriptionResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 4
        
        # When unsubscribing from one of the subscriptions
        let unsubscribeResponse3 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse3.isOk(), $unsubscribeResponse3.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 2
        
        # When unsubscribing from the other subscription
        let unsubscribeResponse4 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "other-pubsub-topic", multipleContentTopicSeq
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse4.isOk(), $unsubscribeResponse4.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "Without existing subscription":
        # When unsubscribing from a non-existent subscription
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the unsubscription is not successful
        check:
          unsubscribeResponse.isErr() # Not subscribed
          unsubscribeResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

      asyncTest "With non existent pubsub topic":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, "pubsub-topic", contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When unsubscribing from a pubsub topic that does not exist
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, "non-existent-pubsub-topic", contentTopicSeq
        )

        # Then the unsubscription is not successful
        check:
          unsubscribeResponse.isErr() # Not subscribed
          unsubscribeResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

      asyncTest "With non existent content topic":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When unsubscribing from a content topic that does not exist
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @["non-existent-content-topic"]
        )

        # Then the unsubscription is not successful
        check:
          unsubscribeResponse.isErr() # Not subscribed
          unsubscribeResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND
      
      asyncTest "Empty content topic":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When unsubscribing from an empty content topic
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, @[]
        )

        # Then the unsubscription is not successful
        check:
          unsubscribeResponse.isErr() # Not subscribed
          unsubscribeResponse.error().kind == FilterSubscribeErrorKind.BAD_REQUEST

    suite "Unsubscribe All":
      asyncTest "Unsubscribe from All Topics, One PubSub Topic":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
        
        # When unsubscribing from all topics
        let unsubscribeResponse = await wakuFilterClient.unsubscribeAll(
          serverRemotePeerInfo
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "Unsubscribe from All Topics, Multiple PubSub Topics":
        # Given a valid subscription
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
        )
        assert subscribeResponse1.isOk(), $subscribeResponse1.error
        assert subscribeResponse2.isOk(), $subscribeResponse2.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
        
        # When unsubscribing from all topics
        let unsubscribeResponse = await wakuFilterClient.unsubscribeAll(
          serverRemotePeerInfo
        )

        # Then the unsubscription is successful
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 0

      asyncTest "Unsubscribe from All Topics from a non-subscribed Service":
        # Given the client is not subscribed to a service
        check:
          wakuFilter.subscriptions.len == 0

        # When unsubscribing from all topics for that client
        let unsubscribeResponse = await wakuFilterClient.unsubscribeAll(
          serverRemotePeerInfo
        )

        # Then the unsubscription is not successful
        check:
          unsubscribeResponse.isErr() # Not subscribed
          unsubscribeResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

    suite "Filter-Push":
      asyncTest "Valid Payload Types":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # And some extra payloads
        let
          JSON_DICTIONARY = getSampleJsonDictionary()
          JSON_LIST = getSampleJsonList()

        # And some valid messages
        let 
          msg1 = fakeWakuMessage(contentTopic=contentTopic, payload=ALPHABETIC)
          msg2 = fakeWakuMessage(contentTopic=contentTopic, payload=ALPHANUMERIC)
          msg3 = fakeWakuMessage(contentTopic=contentTopic, payload=ALPHANUMERIC_SPECIAL)
          msg4 = fakeWakuMessage(contentTopic=contentTopic, payload=EMOJI)
          msg5 = fakeWakuMessage(contentTopic=contentTopic, payload=CODE)
          msg6 = fakeWakuMessage(contentTopic=contentTopic, payload=QUERY)
          msg7 = fakeWakuMessage(contentTopic=contentTopic, payload= $JSON_DICTIONARY)
          msg8 = fakeWakuMessage(contentTopic=contentTopic, payload= $JSON_LIST)
          msg9 = fakeWakuMessage(contentTopic=contentTopic, payload=TEXT_SMALL)
          msg10 = fakeWakuMessage(contentTopic=contentTopic, payload=TEXT_LARGE)
        
        # When sending the alphabetic message
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()

        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1
          msg1.payload.toString() == ALPHABETIC
        
        # When sending the alphanumeric message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2
          msg2.payload.toString() == ALPHANUMERIC
        
        # When sending the alphanumeric special message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg3)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == pubsubTopic
          pushedMsg3 == msg3
          msg3.payload.toString() == ALPHANUMERIC_SPECIAL

        # When sending the emoji message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg4)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic4, pushedMsg4) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic4 == pubsubTopic
          pushedMsg4 == msg4
          msg4.payload.toString() == EMOJI

        # When sending the code message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg5)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic5, pushedMsg5) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic5 == pubsubTopic
          pushedMsg5 == msg5
          msg5.payload.toString() == CODE
        
        # When sending the query message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg6)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic6, pushedMsg6) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic6 == pubsubTopic
          pushedMsg6 == msg6
          msg6.payload.toString() == QUERY
        
        # When sending the table message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg7)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic7, pushedMsg7) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic7 == pubsubTopic
          pushedMsg7 == msg7
          msg7.payload.toString() == $JSON_DICTIONARY
        
        # When sending the list message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg8)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic8, pushedMsg8) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic8 == pubsubTopic
          pushedMsg8 == msg8
          msg8.payload.toString() == $JSON_LIST
        
        # When sending the small text message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg9)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic9, pushedMsg9) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic9 == pubsubTopic
          pushedMsg9 == msg9
          msg9.payload.toString() == TEXT_SMALL
        
        # When sending the large text message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg10)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic10, pushedMsg10) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic10 == pubsubTopic
          pushedMsg10 == msg10
          msg10.payload.toString() == TEXT_LARGE

      asyncTest "Valid Payload Sizes":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # Given some valid payloads
        let
          msg1 = fakeWakuMessage(contentTopic=contentTopic, payload=getByteSequence(1024)) # 1KiB
          msg2 = fakeWakuMessage(contentTopic=contentTopic, payload=getByteSequence(10*1024)) # 10KiB 
          msg3 = fakeWakuMessage(contentTopic=contentTopic, payload=getByteSequence(100*1024)) # 100KiB
          msg4 = fakeWakuMessage(contentTopic=contentTopic, payload=getByteSequence(3*1024*1024 + 1023*1024 + 968)) # 4MiB - 56B -> Max Size (Inclusive Limit)
          msg5 = fakeWakuMessage(contentTopic=contentTopic, payload=getByteSequence(3*1024*1024 + 1023*1024 + 969)) # 4MiB - 55B -> Max Size (Exclusive Limit)
          msg6 = fakeWakuMessage(contentTopic=contentTopic, payload=getByteSequence(3*1024*1024 + 1023*1024 + 970)) # 4MiB - 54B -> Out of Max Size

        # When sending the 1KiB message
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # When sending the 10KiB message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2

        # When sending the 100KiB message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg3)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == pubsubTopic
          pushedMsg3 == msg3

        # When sending the 4MiB - 56B message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg4)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic4, pushedMsg4) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic4 == pubsubTopic
          pushedMsg4 == msg4

        # When sending the 4MiB - 55B message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg5)

        # Then the message is not pushed to the client
        check not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

        # When sending the 4MiB - 54B message
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        await wakuFilter.handleMessage(pubsubTopic, msg6)

        # Then the message is not pushed to the client
        check not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

    suite "Security and Privacy":
      asyncTest "Filter Client can receive messages after Client and Server reboot":
        # Given a clean client and server
        check:
          wakuFilter.subscriptions.len == 0
        
        # When subscribing to a topic
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        
        # Then the subscription is successful
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
        
        # When both are stopped and started
        waitFor allFutures(wakuFilter.stop(), wakuFilterClient.stop())
        waitFor allFutures(wakuFilter.start(), wakuFilterClient.start())

        # Then the suscription is maintained
        check:
          wakuFilter.subscriptions.len == 1

        # When sending a message to the subscription
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic == pubsubTopic
          pushedMsg == msg1

        # When refreshing the subscription after reboot
        let refreshSubscriptionResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the refreshment is successful
        assert refreshSubscriptionResponse.isOk(), $refreshSubscriptionResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
        
        # When sending a message to the refreshed subscription
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2

      asyncTest "Filter Client can receive messages after subscribing and stopping without unsubscribing":
        # Given a valid subscription
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert subscribeResponse.isOk(), $subscribeResponse.error
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
        
        # When the client is stopped
        await wakuFilterClient.stop()

        # Then the subscription is not removed
        check:
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When the server receives a message
        let msg = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg)

        # Then the client receives the message
        check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic == pubsubTopic
          pushedMsg == msg
