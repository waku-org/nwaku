{.used.}

import
  std/[options,tables],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/peerstore

import
  ../../../waku/node/peer_manager,
  ../../../waku/waku_filter_v2,
  ../../../waku/waku_filter_v2/client,
  ../../../waku/waku_core,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/testasync,
  ./client_utils.nim

suite "Waku Filter":
  suite "Subscriber Ping":
    var serverSwitch {.threadvar.}: Switch
    var clientSwitch {.threadvar.}: Switch
    var wakuFilter {.threadvar.}: WakuFilter
    var wakuFilterClient {.threadvar.}: WakuFilterClient
    var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    var pubsubTopic {.threadvar.}: PubsubTopic
    var contentTopics {.threadvar.}: seq[ContentTopic]

    asyncSetup:
      let
        voidHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
          discard

      pubsubTopic = DefaultPubsubTopic
      contentTopics = @[DefaultContentTopic]
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch, voidHandler)
      
      await allFutures(serverSwitch.start(), clientSwitch.start())
      serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    
    asyncTeardown:
      await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())

    asyncTest "Active Subscription Identification":
      # When
      let
        subscribeResponse = await wakuFilterClient.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopics)
        subscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

      # Then
      check:
        subscribedPingResponse.isOk()
        wakuFilter.subscriptions.hasKey(clientSwitch.peerInfo.toRemotePeerInfo().peerId)

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
        clientPeerId = clientSwitch.peerInfo.toRemotePeerInfo().peerId
        subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopics
        )
      
      require subscribeResponse.isOk()
      require wakuFilter.subscriptions.hasKey(clientPeerId)

      # When
      let unsubscribeResponse = await wakuFilterClient.unsubscribe(
        serverRemotePeerInfo, pubsubTopic, contentTopics
      )
      require unsubscribeResponse.isOk()
      require not wakuFilter.subscriptions.hasKey(clientPeerId)

      let unsubscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

      # Then
      check:
        unsubscribedPingResponse.isErr() # Not subscribed
        unsubscribedPingResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND

    asyncTest "Filters included":
      # Given
      let 
        clientPeerId = clientSwitch.peerInfo.toRemotePeerInfo().peerId
        subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopics
        )
      
      require subscribeResponse.isOk()
      require wakuFilter.subscriptions.hasKey(clientPeerId)

      # When
      let unsubscribeResponse = await wakuFilterClient.unsubscribe(
        serverRemotePeerInfo, pubsubTopic, contentTopics
      )

      # Then
      check:
        unsubscribeResponse.isOk()
        not wakuFilter.subscriptions.hasKey(clientPeerId)


  suite "Subscribe":
    asyncTest "PubSub Topic with Single Content Topic":
      discard

    asyncTest "PubSub Topic with Multiple Content Topics":
      discard

    asyncTest "Different PubSub Topic with Different Content Topics":
      discard

    asyncTest "Overlapping Topic Subscription":
      discard

    asyncTest "Refreshing Subscription":
      discard

    asyncTest "Max topic size":
      discard

    asyncTest "Error Handling":
      discard

    asyncTest "Multiple Subscriptions":
      discard

    asyncTest "Service to service subscription":
      discard
