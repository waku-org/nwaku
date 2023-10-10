{.used.}

import
  std/options,
  std/strscans,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto
import
  ../../waku/node/peer_manager,
  ../../waku/waku_core,
  ../../waku/waku_lightpush,
  ../../waku/waku_lightpush/client,
  ../../waku/waku_lightpush/protocol_metrics,
  ../../waku/waku_lightpush/rpc,
  ./testlib/common,
  ./testlib/wakucore

proc newTestWakuLightpushNode(switch: Switch, handler: PushMessageHandler): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuLightPush.new(peerManager, rng, handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLightpushClient(switch: Switch): WakuLightPushClient =
  let
    peerManager = PeerManager.new(switch)
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
    let handler = proc(peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage): Future[WakuLightPushResult[void]] {.async.} =
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
    let handler = proc(peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage): Future[WakuLightPushResult[void]] {.async.} =
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

  asyncTest "incorrectly encoded request should return an erring response":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      handler = proc(peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage): Future[WakuLightPushResult[void]] {.async.} =
        ## this handler will never be called: request must fail earlier
        return ok()
      server = await newTestWakuLightpushNode(serverSwitch, handler)

    ## Given
    let
      fakeBuffer = @[byte(42)]
      fakePeerId = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()
    
    ## When
    let
      pushRpcResponse = await server.handleRequest(fakePeerId, fakeBuffer)
      requestId = pushRpcResponse.requestId
    
    ## Then
    check:
      requestId == ""
      pushRpcResponse.response.isSome()
    
    let resp = pushRpcResponse.response.get()

    check:
      resp.isSuccess == false
      resp.info.isSome()
      ## the error message should start with decodeRpcFailure
      scanf(resp.info.get(), decodeRpcFailure)
