{.used.}

import
  std/[options, strscans],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto

import
  waku/[
    node/peer_manager,
    waku_core,
    waku_lightpush,
    waku_lightpush/client,
    waku_lightpush/protocol_metrics,
  ],
  ../testlib/[assertions, wakucore, testasync, futures],
  ./lightpush_utils,
  ../resources/[pubsub_topics, content_topics, payloads]

suite "Waku Lightpush Client":
  var
    handlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]
    handler {.threadvar.}: PushMessageHandler

    serverSwitch {.threadvar.}: Switch
    clientSwitch {.threadvar.}: Switch
    server {.threadvar.}: WakuLightPush
    client {.threadvar.}: WakuLightPushClient

    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerId {.threadvar.}: PeerId
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic
    message {.threadvar.}: WakuMessage

  asyncSetup:
    handlerFuture = newPushHandlerFuture()
    handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      let msgLen = message.encode().buffer.len
      if msgLen > int(DefaultMaxWakuMessageSize) + 64 * 1024:
        return lighpushErrorResult(
          LightPushErrorCode.PAYLOAD_TOO_LARGE, "length greater than maxMessageSize"
        )
      handlerFuture.complete((pubsubTopic, message))
      # return that we published the message to 1 peer.
      return ok(1)

    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()
    server = await newTestWakuLightpushNode(serverSwitch, handler)
    client = newTestWakuLightpushClient(clientSwitch)

    await allFutures(serverSwitch.start(), clientSwitch.start())

    serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerId = clientSwitch.peerInfo.peerId
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    message = fakeWakuMessage()

  asyncTeardown:
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  suite "Verification of PushRequest Payload":
    asyncTest "Valid Payload Types":
      # Given the following payloads
      let
        message2 = fakeWakuMessage(payloads.ALPHABETIC, content_topics.CURRENT)
        message3 = fakeWakuMessage(payloads.ALPHANUMERIC, content_topics.TESTNET)
        message4 = fakeWakuMessage(payloads.ALPHANUMERIC_SPECIAL, content_topics.PLAIN)
        message5 = fakeWakuMessage(payloads.EMOJI, content_topics.CURRENT)
        message6 = fakeWakuMessage(payloads.CODE, content_topics.TESTNET)
        message7 = fakeWakuMessage(payloads.QUERY, content_topics.PLAIN)
        message8 = fakeWakuMessage(payloads.TEXT_SMALL, content_topics.CURRENT)
        message9 = fakeWakuMessage(payloads.TEXT_LARGE, content_topics.TESTNET)

      # When publishing a valid payload
      let publishResponse =
        await client.publish(some(pubsubTopic), message, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsubTopic, message) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse2 = await client.publish(
        some(pubsub_topics.CURRENT), message2, serverRemotePeerInfo
      )

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse2
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.CURRENT, message2) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse3 = await client.publish(
        some(pubsub_topics.CURRENT_NESTED), message3, serverRemotePeerInfo
      )

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse3
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.CURRENT_NESTED, message3) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse4 = await client.publish(
        some(pubsub_topics.SHARDING), message4, serverRemotePeerInfo
      )

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse4
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.SHARDING, message4) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse5 =
        await client.publish(some(pubsub_topics.PLAIN), message5, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse5
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.PLAIN, message5) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse6 =
        await client.publish(some(pubsub_topics.LEGACY), message6, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse6
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.LEGACY, message6) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse7 = await client.publish(
        some(pubsub_topics.LEGACY_NESTED), message7, serverRemotePeerInfo
      )

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse7
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.LEGACY_NESTED, message7) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse8 = await client.publish(
        some(pubsub_topics.LEGACY_ENCODING), message8, serverRemotePeerInfo
      )

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse8
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.LEGACY_ENCODING, message8) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse9 =
        await client.publish(some(pubsubTopic), message9, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse9
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsubTopic, message9) == handlerFuture.read()

    asyncTest "Valid Payload Sizes":
      # Given some valid payloads
      let
        overheadBytes: uint64 = 112
        message1 =
          fakeWakuMessage(contentTopic = contentTopic, payload = getByteSequence(1024))
          # 1KiB
        message2 = fakeWakuMessage(
          contentTopic = contentTopic, payload = getByteSequence(10 * 1024)
        ) # 10KiB
        message3 = fakeWakuMessage(
          contentTopic = contentTopic, payload = getByteSequence(100 * 1024)
        ) # 100KiB
        message4 = fakeWakuMessage(
          contentTopic = contentTopic,
          payload = getByteSequence(DefaultMaxWakuMessageSize - overheadBytes - 1),
        ) # Inclusive Limit
        message5 = fakeWakuMessage(
          contentTopic = contentTopic,
          payload = getByteSequence(DefaultMaxWakuMessageSize + 64 * 1024),
        ) # Exclusive Limit

      # When publishing the 1KiB payload
      let publishResponse1 =
        await client.publish(some(pubsubTopic), message1, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse1
      check (pubsubTopic, message1) == (await handlerFuture.waitForResult()).value()

      # When publishing the 10KiB payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse2 =
        await client.publish(some(pubsubTopic), message2, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse2
      check (pubsubTopic, message2) == (await handlerFuture.waitForResult()).value()

      # When publishing the 100KiB payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse3 =
        await client.publish(some(pubsubTopic), message3, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse3
      check (pubsubTopic, message3) == (await handlerFuture.waitForResult()).value()

      # When publishing the 1MiB + 63KiB + 911B payload (1113999B)
      handlerFuture = newPushHandlerFuture()
      let publishResponse4 =
        await client.publish(some(pubsubTopic), message4, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse4
      check (pubsubTopic, message4) == (await handlerFuture.waitForResult()).value()

      # When publishing the 1MiB + 63KiB + 912B payload (1114000B)
      handlerFuture = newPushHandlerFuture()
      let publishResponse5 =
        await client.publish(some(pubsubTopic), message5, serverRemotePeerInfo)

      # Then the message is not received by the server
      check:
        publishResponse5.isErr()
        publishResponse5.error.code == LightPushErrorCode.PAYLOAD_TOO_LARGE
        (await handlerFuture.waitForResult()).isErr()

    asyncTest "Invalid Encoding Payload":
      # Given a payload with an invalid encoding
      let fakeBuffer = @[byte(42)]

      # When publishing the payload
      let publishResponse = await server.handleRequest(clientPeerId, fakeBuffer)

      # And the error is returned
      check:
        publishResponse.requestId == "N/A"
        publishResponse.statusCode == LightPushErrorCode.BAD_REQUEST
        publishResponse.statusDesc.isSome()
        scanf(publishResponse.statusDesc.get(), decodeRpcFailure)

    asyncTest "Handle Error":
      # Given a lightpush server that fails
      let
        handlerError = "handler-error"
        handlerFuture2 = newFuture[void]()
        handler2 = proc(
            peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
        ): Future[WakuLightPushResult] {.async.} =
          handlerFuture2.complete()
          return lighpushErrorResult(LightPushErrorCode.PAYLOAD_TOO_LARGE, handlerError)

      let
        serverSwitch2 = newTestSwitch()
        server2 = await newTestWakuLightpushNode(serverSwitch2, handler2)

      await serverSwitch2.start()

      let serverRemotePeerInfo2 = serverSwitch2.peerInfo.toRemotePeerInfo()

      # When publishing a payload
      let publishResponse =
        await client.publish(some(pubsubTopic), message, serverRemotePeerInfo2)

      # Then the response is negative
      check:
        publishResponse.error.code == LightPushErrorCode.PAYLOAD_TOO_LARGE
        publishResponse.error.desc == some(handlerError)
        (await handlerFuture2.waitForResult()).isOk()

      # Cleanup
      await serverSwitch2.stop()

    asyncTest "Check timestamp is not zero":
      ## This test validates that, even the generated message has a timestamp of 0,
      ## the node will eventually set a timestamp when publishing the message.
      let
        zeroTimestamp = 0
        meta = "TEST-META"
        message = fakeWakuMessage(
          payloads.ALPHABETIC, content_topics.CURRENT, meta, zeroTimestamp
        )

      # When publishing a valid payload
      let publishResponse =
        await client.publish(some(pubsubTopic), message, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      let (readPubsubTopic, readMessage) = handlerFuture.read()

      check:
        pubsubTopic == readPubsubTopic
        message.payload == readMessage.payload
        message.contentTopic == readMessage.contentTopic
        message.meta == readMessage.meta
        message.timestamp != readMessage.timestamp
        message.ephemeral == readMessage.ephemeral
        message.proof == readMessage.proof
        message.version == readMessage.version
        readMessage.timestamp > 0

  suite "Verification of PushResponse Payload":
    asyncTest "Positive Responses":
      # When sending a valid PushRequest
      let publishResponse =
        await client.publish(some(pubsubTopic), message, serverRemotePeerInfo)

      # Then the response is positive
      assertResultOk publishResponse

    # TODO: Improve: Add more negative responses variations
    asyncTest "Negative Responses":
      # Given a server that does not support Waku Lightpush
      let
        serverSwitch2 = newTestSwitch()
        serverRemotePeerInfo2 = serverSwitch2.peerInfo.toRemotePeerInfo()

      await serverSwitch2.start()

      # When sending an invalid PushRequest
      let publishResponse =
        await client.publish(some(pubsubTopic), message, serverRemotePeerInfo2)

      # Then the response is negative
      check not publishResponse.isOk()
      check publishResponse.error.code == LightPushErrorCode.NO_PEERS_TO_RELAY
