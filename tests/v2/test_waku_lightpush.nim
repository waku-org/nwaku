{.used.}

import
  std/options,
  testutils/unittests, 
  chronicles,
  chronos, 
  libp2p/crypto/crypto
import
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_lightpush,
  ../../waku/v2/protocol/waku_lightpush/client,
  ./testlib/common,
  ./testlib/switch


proc newTestWakuLightpushNode(switch: Switch, handler: PushMessageHandler): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuLightPush.new(peerManager, rng, handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLightpushClient(switch: Switch): WakuLightPushClient =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
  WakuLightPushClient.new(peerManager, rng)


suite "Waku Lightpush":

  asyncTest "push message to pubsub topic is successful":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let handlerFuture = newFuture[(string, WakuMessage)]()
    let handler = proc(peer: PeerId, pubsubTopic: string, message: WakuMessage): Future[WakuLightPushResult[void]] {.async.} = 
        handlerFuture.complete((pubsubTopic, message))
        return ok()

    let
      server = await newTestWakuLightpushNode(serverSwitch, handler)
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()

    let
      topic = DefaultPubsubTopic
      message = fakeWakuMessage()

    ## When
    let requestRes = await client.publish(topic, message, peer=serverPeerId)

    require await handlerFuture.withTimeout(100.millis)

    ## Then
    check:
      requestRes.isOk()
      handlerFuture.finished()

    let (handledMessagePubsubTopic, handledMessage) = handlerFuture.read()
    check:
      handledMessagePubsubTopic == topic
      handledMessage == message

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "push message to pubsub topic should fail":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let error = "test_failure"
    
    let handlerFuture = newFuture[void]()
    let handler = proc(peer: PeerId, pubsubTopic: string, message: WakuMessage): Future[WakuLightPushResult[void]] {.async.} = 
        handlerFuture.complete()
        return err(error)

    let
      server = await newTestWakuLightpushNode(serverSwitch, handler)
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()

    let
      topic = DefaultPubsubTopic
      message = fakeWakuMessage()

    ## When
    let requestRes = await client.publish(topic, message, peer=serverPeerId)

    require await handlerFuture.withTimeout(100.millis)

    ## Then
    check:
      requestRes.isErr()
      handlerFuture.finished()

    let requestError = requestRes.error
    check:
      requestError == error
  
    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())
