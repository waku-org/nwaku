{.used.}

import
  std/[options, strscans],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import
  ../../../waku/[
    node/peer_manager,
    waku_core,
    waku_lightpush,
    waku_lightpush/client,
    waku_lightpush/common,
    waku_lightpush/protocol_metrics,
    waku_lightpush/rpc,
    waku_lightpush/rpc_codec,
  ],
  ../testlib/[assertions, wakucore, testasync, futures, testutils],
  ./lightpush_utils,
  ../resources/[pubsub_topics, content_topics, payloads]

suite "Rate limited push service":
  asyncTest "push message with rate limit not violated":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    var handlerFuture = newFuture[(string, WakuMessage)]()
    let handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    let
      tokenPeriod = 500.millis
      server =
        await newTestWakuLightpushNode(serverSwitch, handler, some((3, tokenPeriod)))
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()
    let topic = DefaultPubsubTopic

    let sendMsgProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()

      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes = await client.publish(topic, message, peer = serverPeerId)

      require await handlerFuture.withTimeout(50.millis)

      check:
        requestRes.isOk()
        handlerFuture.finished()

      let (handledMessagePubsubTopic, handledMessage) = handlerFuture.read()
      check:
        handledMessagePubsubTopic == topic
        handledMessage == message

    let waitInBetweenFor = 20.millis

    for runCnt in 0 ..< 3:
      let startTime = Moment.now()

      for testCnt in 0 ..< 3:
        await sendMsgProc()
        await sleepAsync(20.millis)

      let endTime = Moment.now()
      let elapsed: Duration = (endTime - startTime)
      await sleepAsync(tokenPeriod - elapsed)
    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "push message with rate limit reject":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    var handlerFuture = newFuture[(string, WakuMessage)]()
    let handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    let
      server =
        await newTestWakuLightpushNode(serverSwitch, handler, some((3, 1000.millis)))
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()
    let topic = DefaultPubsubTopic

    let successProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()
      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(DefaultPubsubTopic, message, peer = serverPeerId)
      discard await handlerFuture.withTimeout(10.millis)

      check:
        requestRes.isOk()
        handlerFuture.finished()
      let (handledMessagePubsubTopic, handledMessage) = handlerFuture.read()
      check:
        handledMessagePubsubTopic == DefaultPubsubTopic
        handledMessage == message

    let rejectProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()
      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(DefaultPubsubTopic, message, peer = serverPeerId)
      discard await handlerFuture.withTimeout(10.millis)

      check:
        requestRes.isErr()
        requestRes.error == "TOO_MANY_REQUESTS"

    for testCnt in 0 .. 2:
      await successProc()
      await sleepAsync(20.millis)

    await rejectProc()

    await sleepAsync(1000.millis)

    ## next one shall succeed due to the rate limit time window has passed
    await successProc()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())
