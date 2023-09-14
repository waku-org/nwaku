{.used.}

import
  std/[options,tables],
  testutils/unittests,
  chronos

import
  ../../waku/node/peer_manager,
  ../../waku/waku_filter_v2,
  ../../waku/waku_filter_v2/client,
  ../../waku/waku_core,
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

      pubsubTopic = DefaultPubsubTopic
      contentTopics = @[DefaultContentTopic]
      serverSwitch = newStandardSwitch()
      clientSwitch = newStandardSwitch()
      wakuFilter = await newTestWakuFilter(serverSwitch)
      wakuFilterClient = await newTestWakuFilterClient(clientSwitch)

      await allFutures(serverSwitch.start(), clientSwitch.start())
      serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    asyncTeardown:
      await allFutures(wakuFilter.stop(), wakuFilterClient.stop(), serverSwitch.stop(), clientSwitch.stop())

    asyncTest "Active Subscription Identification":
      # Given
      let
        clientPeerId = clientSwitch.peerInfo.toRemotePeerInfo().peerId
        subscribeResponse = await wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopics
        )
      require:
        subscribeResponse.isOk()
        wakuFilter.subscriptions.hasKey(clientPeerId)

      # When
      let subscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

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

      require:
        subscribeResponse.isOk()
        wakuFilter.subscriptions.hasKey(clientPeerId)

      # When
      let unsubscribeResponse = await wakuFilterClient.unsubscribe(
        serverRemotePeerInfo, pubsubTopic, contentTopics
      )
      require:
        unsubscribeResponse.isOk()
        not wakuFilter.subscriptions.hasKey(clientPeerId)

      let unsubscribedPingResponse = await wakuFilterClient.ping(serverRemotePeerInfo)

      # Then
      check:
        unsubscribedPingResponse.isErr() # Not subscribed
        unsubscribedPingResponse.error().kind == FilterSubscribeErrorKind.NOT_FOUND
