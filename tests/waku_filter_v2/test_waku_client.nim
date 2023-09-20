{.used.}

import
  std/[options,tables],
  testutils/unittests,
  chronos,
  chronicles,
  os,
  libp2p/peerstore

import
  ../../waku/node/peer_manager,
  ../../waku/waku_filter_v2,
  ../../waku/waku_filter_v2/client,
  ../../waku/waku_core,
  ../testlib/wakucore,
  ../testlib/testasync,
  ./waku_filter_utils.nim

proc newPushHandlerFuture(): Future[(string, WakuMessage)] =
    newFuture[(string, WakuMessage)]()

suite "Waku Filter - End to End":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch
  var wakuFilter {.threadvar.}: WakuFilter
  var wakuFilterClient {.threadvar.}: WakuFilterClient
  var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
  var pubsubTopic {.threadvar.}: PubsubTopic
  var contentTopic {.threadvar.}: ContentTopic
  var contentTopicSeq {.threadvar.}: seq[ContentTopic]
  var clientPeerId {.threadvar.}: PeerId
  var pushHandlerFuture {.threadvar.}: Future[(string, WakuMessage)]

  asyncSetup:
    pushHandlerFuture = newPushHandlerFuture()
    let messagePushHandler: FilterPushHandler = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
    ) {.async, gcsafe, closure.} =
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

  suite "Subscriber Ping":
    asyncTest "Active Subscription Identification":
      # Given
      let 
        subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
      require:
        subscribeResponse.isOk()
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
      require:
        unsubscribeResponse.isOk()
        not wakuFilter.subscriptions.hasKey(clientPeerId)

      let unsubscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

      # Then
      check:
        unsubscribedPingResponse.isErr() # Not subscribed
        unsubscribedPingResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

  suite "Subscribe":
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
      require await pushHandlerFuture.withTimeout(3.seconds)
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
        not await pushHandlerFuture.withTimeout(2.seconds)

      # Given a valid unsubscription to an existing subscription
      let unsubscribeResponse = await wakuFilterClient.unsubscribe(
        serverRemotePeerInfo, pubsubTopic, contentTopicSeq
      )
      require:
        unsubscribeResponse.isOk()
        wakuFilter.subscriptions.len == 0

      # When sending a message to the previously subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg3 = fakeWakuMessage(contentTopic=contentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg3)

      # Then the message is not pushed to the client
      check:
        not await pushHandlerFuture.withTimeout(3.seconds)
      
      # When sending a message to a non-subscribed content topic (after unsubscription)
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg4 = fakeWakuMessage(contentTopic=nonExistentContentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg4)

      # Then
      check:
        not await pushHandlerFuture.withTimeout(2.seconds)

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
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic1 == pubsubTopic
        pushedMsg1 == msg1
      
      # When sending a message to the other subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg2)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
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
        not await pushHandlerFuture.withTimeout(3.seconds)
      
      # Given a valid unsubscription to an existing subscription
      let unsubscribeResponse = await wakuFilterClient.unsubscribe(
        serverRemotePeerInfo, pubsubTopic, contentTopicsSeq
      )
      require:
        unsubscribeResponse.isOk()
        wakuFilter.subscriptions.len == 0
      
      # When sending a message to the previously subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg4 = fakeWakuMessage(contentTopic=contentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg4)

      # Then the message is not pushed to the client
      check:
        not await pushHandlerFuture.withTimeout(3.seconds)

      # When sending a message to the other previously subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg5 = fakeWakuMessage(contentTopic=otherContentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg5)

      # Then the message is not pushed to the client
      check:
        not await pushHandlerFuture.withTimeout(3.seconds)
      
      # When sending a message to a non-subscribed content topic (after unsubscription)
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg6 = fakeWakuMessage(contentTopic=nonExistentContentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg6)

      # Then the message is not pushed to the client
      check:
        not await pushHandlerFuture.withTimeout(3.seconds)

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
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic1 == pubsubTopic
        pushedMsg1 == msg1
      
      # When sending a message to the other subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
      await wakuFilter.handleMessage(otherPubsubTopic, msg2)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
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
        not await pushHandlerFuture.withTimeout(3.seconds)

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
        not await pushHandlerFuture.withTimeout(3.seconds)
      
      # When sending a message to the still subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg5 = fakeWakuMessage(contentTopic=otherContentTopic)
      await wakuFilter.handleMessage(otherPubsubTopic, msg5)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
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

      # When sending a message to the previously subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg6 = fakeWakuMessage(contentTopic=contentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg6)

      # Then the message is not pushed to the client
      check:
        not await pushHandlerFuture.withTimeout(3.seconds)

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
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic1 == pubsubTopic
        pushedMsg1 == msg1
      
      # When sending a message to the other subscribed content topic
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg2 = fakeWakuMessage(contentTopic=otherContentTopic)
      await wakuFilter.handleMessage(otherPubsubTopic, msg2)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
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
        not await pushHandlerFuture.withTimeout(3.seconds)

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
        not await pushHandlerFuture.withTimeout(3.seconds)

    asyncTest "Different PubSub Topics with Same Content Topics, Selectively Unsubscribe":
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
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic1 == pubsubTopic
        pushedMsg1 == msg1

      # When sending a message to (pubsubTopic, otherContentTopic1)
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg2 = fakeWakuMessage(contentTopic=otherContentTopic1)
      await wakuFilter.handleMessage(pubsubTopic, msg2)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic2 == pubsubTopic
        pushedMsg2 == msg2
      
      # When sending a message to (otherPubsubTopic, contentTopic)
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg3 = fakeWakuMessage(contentTopic=contentTopic)
      await wakuFilter.handleMessage(otherPubsubTopic, msg3)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic3 == otherPubsubTopic
        pushedMsg3 == msg3
      
      # When sending a message to (otherPubsubTopic, otherContentTopic2)
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg4 = fakeWakuMessage(contentTopic=otherContentTopic2)
      await wakuFilter.handleMessage(otherPubsubTopic, msg4)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
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
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic5, pushedMsg5) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic5 == pubsubTopic
        pushedMsg5 == msg5

      # When sending a message to (otherPubsubTopic, otherContentTopic2)
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg6 = fakeWakuMessage(contentTopic=otherContentTopic2)
      await wakuFilter.handleMessage(otherPubsubTopic, msg6)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
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
        not await pushHandlerFuture.withTimeout(3.seconds)

    asyncTest "Overlapping Topic Subscription":
      # Given
      let subscribeResponse1 = await wakuFilterClient.subscribe(
        serverRemotePeerInfo, pubsubTopic, contentTopicSeq
      )
      require:
        subscribeResponse1.isOk()
        wakuFilter.subscriptions.hasKey(clientPeerId)
      
      let subscribeResponse2 = await wakuFilterClient.subscribe(
        serverRemotePeerInfo, pubsubTopic, @["other-content-topic"]
      )
      require:
        subscribeResponse2.isOk()
        wakuFilter.subscriptions.hasKey(clientPeerId)
      
      let subscribeResponse3 = await wakuFilterClient.subscribe(
        serverRemotePeerInfo, "other-pubsub-topic", contentTopicSeq
      )
      require:
        subscribeResponse3.isOk()
        wakuFilter.subscriptions.hasKey(clientPeerId)

      # When
      let msg1 = fakeWakuMessage(contentTopic=contentTopic)
      await wakuFilter.handleMessage(pubsubTopic, msg1)

      # Then
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic1 == pubsubTopic
        pushedMsg1 == msg1
      
      # When
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      require (not await pushHandlerFuture.withTimeout(3.seconds)) # Check there're no duplicate messages
      pushHandlerFuture = newPushHandlerFuture() # Reset future due to timeout

      let msg2 = fakeWakuMessage(contentTopic="other-content-topic")
      await wakuFilter.handleMessage(pubsubTopic, msg2)

      # Then
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic2 == pubsubTopic
        pushedMsg2 == msg2

      # When
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      require (not await pushHandlerFuture.withTimeout(3.seconds)) # Check there're no duplicate messages
      pushHandlerFuture = newPushHandlerFuture() # Reset future due to timeout

      let msg3 = fakeWakuMessage(contentTopic=contentTopic)
      await wakuFilter.handleMessage("other-pubsub-topic", msg3)

      # Then
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic3, pushedMsg3) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic3 == "other-pubsub-topic"
        pushedMsg3 == msg3

    asyncTest "Max topic size":
      # When creating a subscription with a topic list of 30 topics
      var topicList: seq[string] = @[]      
      for i in 0..<30:
        let topicName = "topic" & $i
        topicList.add(topicName)

      # Then the subscription is successful
      let subscribeResponse1 = await wakuFilterClient.subscribe(
        serverRemotePeerInfo, pubsubTopic, topicList
      )
      require:
        subscribeResponse1.isOk()
        wakuFilter.subscriptions.hasKey(clientPeerId)

      # When creating a subscription with a topic list of 31 topics
      topicList.add("topic30")

      # Then the subscription is not successful
      let subscribeResponse2 = await wakuFilterClient.subscribe(
        serverRemotePeerInfo, pubsubTopic, topicList
      )
      check:
        subscribeResponse2.isErr() # Not subscribed
        subscribeResponse2.error().kind == FilterSubscribeErrorKind.BAD_REQUEST

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
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic1 == pubsubTopic
        pushedMsg1 == msg1

      # When sending a message to the subscribed content topic on the second service node
      pushHandlerFuture = newPushHandlerFuture() # Clear previous future
      let msg2 = fakeWakuMessage(contentTopic=contentTopic)
      await wakuFilter2.handleMessage(pubsubTopic, msg2)

      # Then the message is pushed to the client
      require await pushHandlerFuture.withTimeout(3.seconds)
      let (pushedMsgPubsubTopic2, pushedMsg2) = pushHandlerFuture.read()
      check:
        pushedMsgPubsubTopic2 == pubsubTopic
        pushedMsg2 == msg2
