{.used.}

import
  std/[options, tables, sequtils],
  testutils/unittests,
  chronos,
  chronicles,
  os,
  libp2p/peerstore

import
  ../../../waku/node/peer_manager,
  ../../../waku/waku_filter_v2,
  ../../../waku/waku_filter_v2/client,
  ../../../waku/waku_filter_v2/subscriptions,
  ../../../waku/waku_core,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/testasync,
  ../testlib/testutils,
  ../testlib/futures,
  ./waku_filter_utils.nim

let FUTURE_TIMEOUT = 1.seconds

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
    var pushHandlerFuture {.threadvar.}: Future[(string, WakuMessage)]

    asyncSetup:
      pushHandlerFuture = newPushHandlerFuture()
      messagePushHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
      ) {.async, closure, gcsafe.} =
        pushHandlerFuture.complete((pubsubTopic, message))

      pubsubTopic = DefaultPubsubTopic
      contentTopic = DefaultContentTopic
      contentTopicSeq = @[DefaultContentTopic]
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
        require:
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When
        let subscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

        # Then
        check:
          subscribedPingResponse.isOk()
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

        require:
          subscribeResponse.isOk()
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When
        let unsubscribeResponse = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        assert unsubscribeResponse.isOk(), $unsubscribeResponse.error
        require:
          unsubscribeResponse.isOk()
          not wakuFilter.subscriptions.hasKey(clientPeerId)

        let unsubscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

        # Then
        check:
          unsubscribedPingResponse.isErr() # Not subscribed
          unsubscribedPingResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

    suite "Subscribe":
      asyncTest "Server remote peer info doesn't match an online server":
        # Given an offline service node
        let offlineServerSwitch = newStandardSwitch()
        let offlineWakuFilter = await newTestWakuFilter(offlineServerSwitch)
        let offlineServerRemotePeerInfo = offlineServerSwitch.peerInfo.toRemotePeerInfo()

        # When subscribing to the offline service node
        let subscribeResponse = await wakuFilterClient.subscribe(
          offlineServerRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is not successful
        check:
          subscribeResponse.isErr() # Not subscribed
          subscribeResponse.error().kind == FilterSubscribeErrorKind.PEER_DIAL_FAILURE

      asyncTest "PubSub Topic with Single Content Topic":
        # Given
        let nonExistentContentTopic = "non-existent-content-topic"

        # When subscribing to a content topic
        let subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is successful
        check:
          subscribeResponse.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When sending a message to the subscribed content topic
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
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
        require:
          unsubscribeResponse.isOk()
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
        require:
          subscribeResponse.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicsSeq

        # When sending a message to the one of the subscribed content topics
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1
        
        # When sending a message to the other subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
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
        require:
          unsubscribeResponse.isOk()
          wakuFilter.subscriptions.len == 0
        
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
        check:
          subscribeResponse1.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When subscribing to a different pubsub topic
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, otherPubsubTopic, otherContentTopicSeq
        )

        # Then the subscription is successful
        check:
          subscribeResponse2.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq & otherContentTopicSeq

        # When sending a message to one of the subscribed content topics
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1
        
        # When sending a message to the other subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg2)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
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
        check:
          unsubscribeResponse1.isOk()
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
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == otherPubsubTopic
          pushedMsg3 == msg5
        
        # When unsubscribing from the other subscription
        let unsubscribeResponse2 = await wakuFilterClient.unsubscribe(
          serverRemotePeerInfo, otherPubsubTopic, otherContentTopicSeq
        )

        # Then the unsubscription is successful
        check:
          unsubscribeResponse2.isOk()
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
        check:
          subscribeResponse1.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When subscribing to a different content topic
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, otherPubsubTopic, otherContentTopicSeq
        )

        # Then
        check:
          subscribeResponse2.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq & otherContentTopicSeq

        # When sending a message to one of the subscribed content topics
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1
        
        # When sending a message to the other subscribed content topic
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg2)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
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
        check:
          unsubscribeResponse.isOk()
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
        check:
          subscribeResponse1.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicsSeq1

        # When subscribing to a different pubsub topic
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, otherPubsubTopic, contentTopicsSeq2
        )

        # Then the subscription is successful
        check:
          subscribeResponse2.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicsSeq1 & contentTopicsSeq2

        # When sending a message to (pubsubTopic, contentTopic)
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # When sending a message to (pubsubTopic, otherContentTopic1)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=otherContentTopic1)
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2
        
        # When sending a message to (otherPubsubTopic, contentTopic)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg3 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(otherPubsubTopic, msg3)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == otherPubsubTopic
          pushedMsg3 == msg3
        
        # When sending a message to (otherPubsubTopic, otherContentTopic2)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg4 = fakeWakuMessage(contentTopic=otherContentTopic2)
        await wakuFilter.handleMessage(otherPubsubTopic, msg4)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
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
        check:
          unsubscribeResponse1.isOk()
          unsubscribeResponse2.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == @[contentTopic, otherContentTopic2]

        # When sending a message to (pubsubTopic, contentTopic)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg5 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg5)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic5, pushedMsg5) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic5 == pubsubTopic
          pushedMsg5 == msg5

        # When sending a message to (otherPubsubTopic, otherContentTopic2)
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg6 = fakeWakuMessage(contentTopic=otherContentTopic2)
        await wakuFilter.handleMessage(otherPubsubTopic, msg6)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
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
        require:
          subscribeResponse1.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId).len == 30

        # When refreshing the subscription with a topic list of 30 topics
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, topicSeq
        )

        # Then the subscription is successful
        check:
          subscribeResponse2.isOk()
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
          require:
            subscribeResponse.isOk()

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
        require:
          subscribeResponse1.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When subscribing to the second service node
        let subscriptionResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo2, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is successful
        check:
          subscriptionResponse2.isOk()
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
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # When sending a message to the subscribed content topic on the second service node
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        let msg2 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter2.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2

  suite "MessagePushHandler - Msg List":
    var serverSwitch {.threadvar.}: Switch
    var clientSwitch {.threadvar.}: Switch
    var wakuFilter {.threadvar.}: WakuFilter
    var wakuFilterClient {.threadvar.}: WakuFilterClient
    var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    var pubsubTopic {.threadvar.}: PubsubTopic
    var contentTopic {.threadvar.}: ContentTopic
    var contentTopicSeq {.threadvar.}: seq[ContentTopic]
    var clientPeerId {.threadvar.}: PeerId
    var msgList {.threadvar.}: seq[(PubsubTopic, WakuMessage)]
    var pushHandlerFuture {.threadvar.}: Future[(string, WakuMessage)]

    asyncSetup:
      pushHandlerFuture = newPushHandlerFuture()
      msgList = @[]
      let messagePushHandler: FilterPushHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[void] {.async, closure, gcsafe.} =
        msgList.add((pubsubTopic, message))
        pushHandlerFuture.complete((pubsubTopic, message))

      pubsubTopic = DefaultPubsubTopic
      contentTopic = DefaultContentTopic
      contentTopicSeq = @[DefaultContentTopic]
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch)
      wakuFilterClient.registerPushHandler(messagePushHandler)
      
      await allFutures(serverSwitch.start(), clientSwitch.start())
      serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
      clientPeerId = clientSwitch.peerInfo.toRemotePeerInfo().peerId
    
    asyncTeardown:
      await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())

    suite "Subscribe":
      asyncTest "Refreshing Subscription":
        # Given a valid subscription  
        let subscribeResponse1 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
        require:
          subscribeResponse1.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq
        
        # When refreshing the subscription
        let subscribeResponse2 = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )

        # Then the subscription is successful
        check:
          subscribeResponse2.isOk()
          wakuFilter.subscriptions.len == 1
          wakuFilter.subscriptions.hasKey(clientPeerId)
          wakuFilter.getSubscribedContentTopics(clientPeerId) == contentTopicSeq

        # When sending a message to the refreshed subscription
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # And the message is not duplicated
        check:
          msgList.len == 1
          msgList[0][0] == pubsubTopic
          msgList[0][1] == msg1

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
        require:
          subscribeResponse1.isOk()
          subscribeResponse2.isOk()
          subscribeResponse3.isOk()
          wakuFilter.subscriptions.hasKey(clientPeerId)

        # When sending a message to the overlapping subscription 1
        let msg1 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage(pubsubTopic, msg1)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic1 == pubsubTopic
          pushedMsg1 == msg1

        # And the message is not duplicated
        check:
          msgList.len == 1
          msgList[0][0] == pubsubTopic
          msgList[0][1] == msg1

        # When sending a message to the overlapping subscription 2
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        require (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)) # Check there're no duplicate messages
        pushHandlerFuture = newPushHandlerFuture() # Reset future due to timeout

        let msg2 = fakeWakuMessage(contentTopic="other-content-topic")
        await wakuFilter.handleMessage(pubsubTopic, msg2)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic2 == pubsubTopic
          pushedMsg2 == msg2

        # And the message is not duplicated
        check:
          msgList.len == 2
          msgList[1][0] == pubsubTopic
          msgList[1][1] == msg2

        # When sending a message to the overlapping subscription 3
        pushHandlerFuture = newPushHandlerFuture() # Clear previous future
        require (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)) # Check there're no duplicate messages
        pushHandlerFuture = newPushHandlerFuture() # Reset future due to timeout

        let msg3 = fakeWakuMessage(contentTopic=contentTopic)
        await wakuFilter.handleMessage("other-pubsub-topic", msg3)

        # Then the message is pushed to the client
        require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
        check:
          pushedMsgPubsubTopic3 == "other-pubsub-topic"
          pushedMsg3 == msg3

        # And the message is not duplicated
        check:
          msgList.len == 3
          msgList[2][0] == "other-pubsub-topic"
          msgList[2][1] == msg3
