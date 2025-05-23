{.used.}

import
  std/[options, strscans],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import
  waku/[
    node/peer_manager,
    waku_core,
    waku_lightpush,
    waku_lightpush/client,
    waku_lightpush/protocol_metrics,
  ],
  ../testlib/[assertions, wakucore, testasync, futures, testutils],
  ./lightpush_utils,
  ../resources/[pubsub_topics, content_topics, payloads]

suite "Lightpush Server Incentivization Test":
  var
    serverSwitch {.threadvar.}: Switch
    clientSwitch {.threadvar.}: Switch
    server {.threadvar.}: WakuLightPush
    client {.threadvar.}: WakuLightPushClient
    serverPeerId {.threadvar.}: RemotePeerInfo
    handlerFuture {.threadvar.}: Future[(string, WakuMessage)]
    tokenPeriod {.threadvar.}: Duration
    waitInBetweenFor {.threadvar.}: Duration
    firstWaitExtend {.threadvar.}: Duration

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    handlerFuture = newFuture[(string, WakuMessage)]()
    let handler: PushMessageHandler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return lightpushSuccessResult(1)

    tokenPeriod = 500.millis
    server = await newTestWakuLightpushNode(
      serverSwitch, handler, some((3, tokenPeriod)), eligibilityEnabled = true
    )
    client = newTestWakuLightpushClient(clientSwitch)
    serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()

    waitInBetweenFor = 20.millis
    firstWaitExtend = 300.millis

  asyncTeardown:
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "message with valid eligibility proof is published":
    let sendMsgProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()

      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(some(DefaultPubsubTopic), message, peer = serverPeerId)

      check await handlerFuture.withTimeout(50.millis)

      check:
        requestRes.isOk()
        handlerFuture.finished()

      let (handledMessagePubsubTopic, handledMessage) = handlerFuture.read()

      check:
        handledMessagePubsubTopic == DefaultPubsubTopic
        handledMessage == message

    for runCnt in 0 ..< 3:
      let startTime = Moment.now()
      for testCnt in 0 ..< 3:
        await sendMsgProc()
        await sleepAsync(waitInBetweenFor)

      let endTime = Moment.now()
      let elapsed = (endTime - startTime)
      await sleepAsync(tokenPeriod - elapsed + firstWaitExtend)
      firstWaitExtend = 100.millis
