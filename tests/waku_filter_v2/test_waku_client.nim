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

    asyncSetup:
      let
        voidHandler: MessagePushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) =
          discard

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
        subscribeResponse = await wakuFilterClient.subscribe(serverRemotePeerInfo, DefaultPubsubTopic, @[DefaultContentTopic])
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
          serverRemotePeerInfo, DefaultPubsubTopic, @[DefaultContentTopic]
        )
      
      require subscribeResponse.isOk()
      require wakuFilter.subscriptions.hasKey(clientPeerId)

      # When
      let unsubscribeResponse = await wakuFilterClient.unsubscribe(
        serverRemotePeerInfo, DefaultPubsubTopic, @[DefaultContentTopic]
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
          serverRemotePeerInfo, DefaultPubsubTopic, @[DefaultContentTopic]
        )
      
      require subscribeResponse.isOk()
      require wakuFilter.subscriptions.hasKey(clientPeerId)

      # When
      let unsubscribeResponse = await wakuFilterClient.unsubscribe(
        serverRemotePeerInfo, DefaultPubsubTopic, @[DefaultContentTopic]
      )

      # Then
      check:
        unsubscribeResponse.isOk()
        not wakuFilter.subscriptions.hasKey(clientPeerId)
