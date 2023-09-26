{.used.}

import
  std/[options, sequtils, strutils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/messages
import
  ../../../waku/node/peer_manager,
  ../../../waku/waku_core,
  ../../../waku/waku_relay,
  ../testlib/common,
  ../testlib/wakucore


proc noopRawHandler(): WakuRelayHandler =
    var handler: WakuRelayHandler
    handler = proc(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} = discard
    handler


proc newTestWakuRelay(switch = newTestSwitch()): Future[WakuRelay] {.async.} =
  let proto = WakuRelay.new(switch).tryGet()
  await proto.start()

  let protocolMatcher = proc(proto: string): bool {.gcsafe.} =
    return proto.startsWith(WakuRelayCodec)

  switch.mount(proto, protocolMatcher)

  return proto


suite "Waku Relay":

  asyncTest "subscribe and add handler to topics":
    ## Setup
    let nodeA = await newTestWakuRelay()

    ## Given
    let
      networkA = "test-network1"
      networkB = "test-network2"

    ## when
    discard nodeA.subscribe(networkA, noopRawHandler())
    discard nodeA.subscribe(networkB, noopRawHandler())

    ## Then
    check:
      nodeA.isSubscribed(networkA)
      nodeA.isSubscribed(networkB)

    let subscribedTopics = toSeq(nodeA.subscribedTopics)
    check:
      subscribedTopics.len == 2
      subscribedTopics.contains(networkA)
      subscribedTopics.contains(networkB)

    ## Cleanup
    await nodeA.stop()

  asyncTest "unsubscribe all handlers from topic":
    ## Setup
    let nodeA = await newTestWakuRelay()

    ## Given
    let
      networkA = "test-network1"
      networkB = "test-network2"
      networkC = "test-network3"

    discard nodeA.subscribe(networkA, noopRawHandler())
    discard nodeA.subscribe(networkB, noopRawHandler())
    discard nodeA.subscribe(networkC, noopRawHandler())

    let topics = toSeq(nodeA.subscribedTopics)
    require:
      topics.len == 3
      topics.contains(networkA)
      topics.contains(networkB)
      topics.contains(networkC)

    ## When
    nodeA.unsubscribeAll(networkA)

    ## Then
    check:
      nodeA.isSubscribed(networkB)
      nodeA.isSubscribed(networkC)
      not nodeA.isSubscribed(networkA)

    let subscribedTopics = toSeq(nodeA.subscribedTopics)
    check:
      subscribedTopics.len == 2
      subscribedTopics.contains(networkB)
      subscribedTopics.contains(networkC)
      not subscribedTopics.contains(networkA)

    ## Cleanup
    await nodeA.stop()

  asyncTest "publish a message into a topic":
    ## Setup
    let
      srcSwitch = newTestSwitch()
      srcPeerManager = PeerManager.new(srcSwitch)
      srcNode = await newTestWakuRelay(srcSwitch)
      dstSwitch = newTestSwitch()
      dstPeerManager = PeerManager.new(dstSwitch)
      dstNode = await newTestWakuRelay(dstSwitch)

    await allFutures(srcSwitch.start(), dstSwitch.start())

    let dstPeerInfo = dstPeerManager.switch.peerInfo.toRemotePeerInfo()
    let connOk = await srcPeerManager.connectRelay(dstPeerInfo)
    require:
      connOk == true

    ## Given
    let networkTopic = "test-network1"
    let message = fakeWakuMessage()

    # Self subscription (triggerSelf = true)
    let srcSubsFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc srcSubsHandler(topic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
      srcSubsFut.complete((topic, message))

    discard srcNode.subscribe(networkTopic, srcSubsHandler)

    # Subscription
    let dstSubsFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc dstSubsHandler(topic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
      dstSubsFut.complete((topic, message))

    discard dstNode.subscribe(networkTopic, dstSubsHandler)

    await sleepAsync(500.millis)

    ## When
    discard await srcNode.publish(networkTopic, message)

    ## Then
    require:
      await srcSubsFut.withTimeout(5.seconds)
      await dstSubsFut.withTimeout(5.seconds)

    let (srcTopic, srcMsg) = srcSubsFut.read()
    check:
      srcTopic == networkTopic
      srcMsg == message

    let (dstTopic, dstMsg) = dstSubsFut.read()
    check:
      dstTopic == networkTopic
      dstMsg == message

    ## Cleanup
    await allFutures(srcSwitch.stop(), dstSwitch.stop())

  asyncTest "content topic validator as a message subscription filter":
    ## Setup
    let
      srcSwitch = newTestSwitch()
      srcPeerManager = PeerManager.new(srcSwitch)
      srcNode = await newTestWakuRelay(srcSwitch)
      dstSwitch = newTestSwitch()
      dstPeerManager = PeerManager.new(dstSwitch)
      dstNode = await newTestWakuRelay(dstSwitch)

    await allFutures(srcSwitch.start(), dstSwitch.start())

    let dstPeerInfo = dstPeerManager.switch.peerInfo.toRemotePeerInfo()
    let connOk = await srcPeerManager.connectRelay(dstPeerInfo)
    require:
      connOk == true

    ## Given
    let networkTopic = "test-network1"
    let contentTopic = "test-content1"

    let message = fakeWakuMessage(contentTopic=contentTopic)
    let messages = @[
      fakeWakuMessage(contentTopic="any"),
      fakeWakuMessage(contentTopic="any"),
      fakeWakuMessage(contentTopic="any"),
      message,
      fakeWakuMessage(contentTopic="any"),
    ]

    # Subscription
    let dstSubsFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc dstSubsHandler(topic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
      dstSubsFut.complete((topic, message))

    discard dstNode.subscribe(networkTopic, dstSubsHandler)

    await sleepAsync(500.millis)

    # Validator
    proc validator(topic: PubsubTopic, msg: WakuMessage): Future[ValidationResult] {.async.} =
      # only relay messages with contentTopic1
      if msg.contentTopic != contentTopic:
        return ValidationResult.Reject

      return ValidationResult.Accept

    dstNode.addValidator(networkTopic, validator)

    ## When
    for msg in messages:
      discard await srcNode.publish(networkTopic, msg)

    ## Then
    require:
      await dstSubsFut.withTimeout(5.seconds)

    let (dstTopic, dstMsg) = dstSubsFut.read()
    check:
      dstTopic == networkTopic
      dstMsg == message

    ## Cleanup
    await allFutures(srcSwitch.stop(), dstSwitch.stop())
