{.used.}

import
  std/[options, tempfiles, net],
  testutils/unittests,
  chronos,
  std/strformat,
  libp2p/crypto/crypto

import
  waku/[
    waku_core,
    node/peer_manager,
    node/waku_node,
    waku_lightpush_legacy,
    waku_lightpush_legacy/common,
    waku_lightpush_legacy/protocol_metrics,
    waku_rln_relay,
  ],
  ../testlib/[wakucore, wakunode, testasync, futures, testutils],
  ../resources/payloads

suite "Waku Legacy Lightpush - End To End":
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
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

    await allFutures(server.start(), client.start())
    await server.start()

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await server.mountLegacyLightpush() # without rln-relay
    client.mountLegacyLightpushClient()

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
      lightpushClient.mountLegacyLightpushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.legacyLightpushPublish(
        some(pubsubTopic), message, serverRemotePeerInfo
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"

      assert (publishResponse.error == protocol_metrics.notPublishedAnyPeer),
        "incorrect error response"

  suite "Waku LightPush Validation Tests":
    asyncTest "Validate message size exceeds limit":
      let msgOverLimit = fakeWakuMessage(
        contentTopic = contentTopic,
        payload = getByteSequence(DefaultMaxWakuMessageSize + 64 * 1024),
      )

      # When the client publishes an over-limit message
      let publishResponse = await client.legacyLightpushPublish(
        some(pubsubTopic), msgOverLimit, serverRemotePeerInfo
      )

      check:
        publishResponse.isErr()
        publishResponse.error ==
          fmt"Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"

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
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

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
    await server.mountLegacyLightPush()
    client.mountLegacyLightPushClient()

    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    message = fakeWakuMessage()

  asyncTeardown:
    await server.stop()

  suite "Lightpush attaching RLN proofs":
    xasyncTest "Message is published when RLN enabled":
      # Given a light lightpush client
      let lightpushClient =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      lightpushClient.mountLegacyLightPushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.legacyLightpushPublish(
        some(pubsubTopic), message, serverRemotePeerInfo
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"
      check publishResponse.error == protocol_metrics.notPublishedAnyPeer

suite "Waku Legacy Lightpush message delivery":
  asyncTest "Legacy lightpush message flow succeed":
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
    await bridgeNode.mountLegacyLightPush()
    lightNode.mountLegacyLightPushClient()

    discard await lightNode.peerManager.dialPeer(
      bridgeNode.peerInfo.toRemotePeerInfo(), WakuLegacyLightPushCodec
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
      assert false, "Failed to subscribe to topic:" & $error

    # Wait for subscription to take effect
    await sleepAsync(100.millis)

    ## When
    let res = await lightNode.legacyLightpushPublish(some(CustomPubsubTopic), message)
    assert res.isOk(), $res.error

    ## Then
    check await completionFutRelay.withTimeout(5.seconds)

    ## Cleanup
    await allFutures(lightNode.stop(), bridgeNode.stop(), destNode.stop())
