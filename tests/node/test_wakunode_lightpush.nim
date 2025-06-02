{.used.}

import
  std/[options, tempfiles],
  testutils/unittests,
  chronos,
  std/strformat,
  libp2p/crypto/crypto

import
  waku/[waku_core, node/peer_manager, node/waku_node, waku_lightpush, waku_rln_relay],
  ../testlib/[wakucore, wakunode, testasync, futures],
  ../resources/payloads

const PublishedToOnePeer = 1

suite "Waku Lightpush - End To End":
  var
    handlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]
    handler {.threadvar.}: PushMessageHandler

    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode

    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic
    message {.threadvar.}: WakuMessage

  asyncSetup:
    handlerFuture = newPushHandlerFuture()
    handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok(PublishedToOnePeer)

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

    await allFutures(server.start(), client.start())
    await server.start()

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await server.mountLightpush() # without rln-relay
    client.mountLightpushClient()

    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    message = fakeWakuMessage()

  asyncTeardown:
    await server.stop()

  suite "Assessment of Message Relaying Mechanisms":
    asyncTest "Via 11/WAKU2-RELAY from Relay/Full Node":
      # Given a light lightpush client
      let lightpushClient =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      lightpushClient.mountLightpushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.lightpushPublish(
        some(pubsubTopic), message, some(serverRemotePeerInfo)
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error.code

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"

      assert (publishResponse.error.code == NO_PEERS_TO_RELAY),
        "incorrect error response"

  suite "Waku LightPush Validation Tests":
    asyncTest "Validate message size exceeds limit":
      let msgOverLimit = fakeWakuMessage(
        contentTopic = contentTopic,
        payload = getByteSequence(DefaultMaxWakuMessageSize + 64 * 1024),
      )

      # When the client publishes an over-limit message
      let publishResponse = await client.lightpushPublish(
        some(pubsubTopic), msgOverLimit, some(serverRemotePeerInfo)
      )

      check:
        publishResponse.isErr()
        publishResponse.error.code == INVALID_MESSAGE_ERROR
        publishResponse.error.desc ==
          some(fmt"Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes")

suite "RLN Proofs as a Lightpush Service":
  var
    handlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]
    handler {.threadvar.}: PushMessageHandler

    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode

    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic
    message {.threadvar.}: WakuMessage

  asyncSetup:
    handlerFuture = newPushHandlerFuture()
    handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok(PublishedToOnePeer)

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

    # mount rln-relay
    let wakuRlnConfig = WakuRlnConfig(
      dynamic: false,
      credIndex: some(1.uint),
      userMessageLimit: 1,
      epochSizeSec: 1,
      treePath: genTempPath("rln_tree", "wakunode"),
    )

    await allFutures(server.start(), client.start())
    await server.start()

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await server.mountRlnRelay(wakuRlnConfig)
    await server.mountLightPush()
    client.mountLightPushClient()

    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    message = fakeWakuMessage()

  asyncTeardown:
    await server.stop()

  suite "Lightpush attaching RLN proofs":
    asyncTest "Message is published when RLN enabled":
      # Given a light lightpush client
      let lightpushClient =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      lightpushClient.mountLightPushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.lightpushPublish(
        some(pubsubTopic), message, some(serverRemotePeerInfo)
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"
      check publishResponse.error.code == NO_PEERS_TO_RELAY

suite "Waku Lightpush message delivery":
  asyncTest "lightpush message flow succeed":
    ## Setup
    let
      lightNodeKey = generateSecp256k1Key()
      lightNode = newTestWakuNode(lightNodeKey, parseIpAddress("0.0.0.0"), Port(0))
      bridgeNodeKey = generateSecp256k1Key()
      bridgeNode = newTestWakuNode(bridgeNodeKey, parseIpAddress("0.0.0.0"), Port(0))
      destNodeKey = generateSecp256k1Key()
      destNode = newTestWakuNode(destNodeKey, parseIpAddress("0.0.0.0"), Port(0))

    await allFutures(destNode.start(), bridgeNode.start(), lightNode.start())

    (await destNode.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await bridgeNode.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await bridgeNode.mountLightPush()
    lightNode.mountLightPushClient()

    discard await lightNode.peerManager.dialPeer(
      bridgeNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )
    await sleepAsync(100.milliseconds)
    await destNode.connectToNodes(@[bridgeNode.peerInfo.toRemotePeerInfo()])

    ## Given
    const CustomPubsubTopic = "/waku/2/rs/0/1"
    let message = fakeWakuMessage()

    var completionFutRelay = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == CustomPubsubTopic
        msg == message
      completionFutRelay.complete(true)

    destNode.subscribe((kind: PubsubSub, topic: CustomPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to relay"

    # Wait for subscription to take effect
    await sleepAsync(100.millis)

    ## When
    let res = await lightNode.lightpushPublish(some(CustomPubsubTopic), message)
    assert res.isOk(), $res.error
    assert res.get() == 1, "Expected to relay the message to 1 node"

    ## Then
    check await completionFutRelay.withTimeout(5.seconds)

    ## Cleanup
    await allFutures(lightNode.stop(), bridgeNode.stop(), destNode.stop())
