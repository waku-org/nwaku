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
    waku_lightpush/common,
    waku_lightpush/protocol_metrics,
    waku_lightpush/rpc,
    waku_lightpush/rpc_codec,
    /incentivization/reputation_manager,
  ],
  ../testlib/[assertions, wakucore, testasync, futures, testutils],
  ./lightpush_utils,
  ../resources/[pubsub_topics, content_topics, payloads]

suite "Waku Lightpush Client":
  var
    handlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]
    handlerFutureFailsLightpush {.threadvar.}: Future[void]

    handler {.threadvar.}: PushMessageHandler
    handlerFailsLightpush {.threadvar.}: PushMessageHandler

    serverSwitch {.threadvar.}: Switch
    serverSwitchFailsLightpush {.threadvar.}: Switch
    clientSwitch {.threadvar.}: Switch

    server {.threadvar.}: WakuLightPush
    serverFailsLightpush {.threadvar.}: WakuLightPush
    client {.threadvar.}: WakuLightPushClient

    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    serverRemotePeerInfoFailsLightpush {.threadvar.}: RemotePeerInfo

    clientPeerId {.threadvar.}: PeerId
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic
    message {.threadvar.}: WakuMessage

  const handlerError = "handler-error"

  asyncSetup:
    handlerFuture = newPushHandlerFuture()
    handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      let msgLen = message.encode().buffer.len
      if msgLen > int(DefaultMaxWakuMessageSize) + 64 * 1024:
        return err("length greater than maxMessageSize")
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    # A Lightpush server that fails
    handlerFutureFailsLightpush = newFuture[void]()
    handlerFailsLightpush = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFutureFailsLightpush.complete()
      return err(handlerError)

    serverSwitch = newTestSwitch()
    serverSwitchFailsLightpush = newTestSwitch()
    clientSwitch = newTestSwitch()

    server = await newTestWakuLightpushNode(serverSwitch, handler)
    serverFailsLightpush =
      await newTestWakuLightpushNode(serverSwitchFailsLightpush, handlerFailsLightpush)
    ## FIXME: how to pass reputationEnabled from config to here? should we?
    client = newTestWakuLightpushClient(clientSwitch, reputationEnabled = true)

    await allFutures(
      serverSwitch.start(), serverSwitchFailsLightpush.start(), clientSwitch.start()
    )

    serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    serverRemotePeerInfoFailsLightpush =
      serverSwitchFailsLightpush.peerInfo.toRemotePeerInfo()
    clientPeerId = clientSwitch.peerInfo.peerId
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    message = fakeWakuMessage()

  asyncTeardown:
    await allFutures(
      clientSwitch.stop(), serverSwitch.stop(), serverSwitchFailsLightpush.stop()
    )

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
        await client.publish(pubsubTopic, message, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsubTopic, message) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse2 =
        await client.publish(pubsub_topics.CURRENT, message2, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse2
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.CURRENT, message2) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse3 = await client.publish(
        pubsub_topics.CURRENT_NESTED, message3, serverRemotePeerInfo
      )

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse3
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.CURRENT_NESTED, message3) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse4 =
        await client.publish(pubsub_topics.SHARDING, message4, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse4
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.SHARDING, message4) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse5 =
        await client.publish(pubsub_topics.PLAIN, message5, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse5
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.PLAIN, message5) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse6 =
        await client.publish(pubsub_topics.LEGACY, message6, serverRemotePeerInfo)

      # Then the message is received by the server
      discard await handlerFuture.withTimeout(FUTURE_TIMEOUT)
      assertResultOk publishResponse6
      check handlerFuture.finished()

      # And the message is received with the correct topic and payload
      check (pubsub_topics.LEGACY, message6) == handlerFuture.read()

      # When publishing a valid payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse7 = await client.publish(
        pubsub_topics.LEGACY_NESTED, message7, serverRemotePeerInfo
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
        pubsub_topics.LEGACY_ENCODING, message8, serverRemotePeerInfo
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
        await client.publish(pubsubTopic, message9, serverRemotePeerInfo)

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
        await client.publish(pubsubTopic, message1, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse1
      check (pubsubTopic, message1) == (await handlerFuture.waitForResult()).value()

      # When publishing the 10KiB payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse2 =
        await client.publish(pubsubTopic, message2, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse2
      check (pubsubTopic, message2) == (await handlerFuture.waitForResult()).value()

      # When publishing the 100KiB payload
      handlerFuture = newPushHandlerFuture()
      let publishResponse3 =
        await client.publish(pubsubTopic, message3, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse3
      check (pubsubTopic, message3) == (await handlerFuture.waitForResult()).value()

      # When publishing the 1MiB + 63KiB + 911B payload (1113999B)
      handlerFuture = newPushHandlerFuture()
      let publishResponse4 =
        await client.publish(pubsubTopic, message4, serverRemotePeerInfo)

      # Then the message is received by the server
      assertResultOk publishResponse4
      check (pubsubTopic, message4) == (await handlerFuture.waitForResult()).value()

      # When publishing the 1MiB + 63KiB + 912B payload (1114000B)
      handlerFuture = newPushHandlerFuture()
      let publishResponse5 =
        await client.publish(pubsubTopic, message5, serverRemotePeerInfo)

      # Then the message is not received by the server
      check:
        not publishResponse5.isOk()
        (await handlerFuture.waitForResult()).isErr()

    asyncTest "Invalid Encoding Payload":
      # Given a payload with an invalid encoding
      let fakeBuffer = @[byte(42)]

      # When publishing the payload
      let publishResponse = await server.handleRequest(clientPeerId, fakeBuffer)

      # Then the response is negative
      check:
        publishResponse.requestId == ""

      # And the error is returned
      let response = publishResponse.response.get()
      check:
        response.isSuccess == false
        response.info.isSome()
        scanf(response.info.get(), decodeRpcFailure)

    asyncTest "Handle Error":
      # When publishing a payload
      let publishResponse =
        await client.publish(pubsubTopic, message, serverRemotePeerInfoFailsLightpush)

      # Then the response is negative
      check:
        publishResponse.error() == handlerError
        (await handlerFutureFailsLightpush.waitForResult()).isOk()

  suite "Verification of PushResponse Payload":
    asyncTest "Positive Responses":
      # When sending a valid PushRequest
      let publishResponse =
        await client.publish(pubsubTopic, message, serverRemotePeerInfo)

      # Then the response is positive
      assertResultOk publishResponse

      if client.reputationManager.isSome:
        check client.reputationManager.get().getReputation(serverRemotePeerInfo.peerId) ==
          some(true)

    # TODO: Improve: Add more negative responses variations
    asyncTest "Negative Responses":
      # Given a server that does not support Waku Lightpush
      let
        serverSwitchFailsLightpush = newTestSwitch()
        serverRemotePeerInfoFailsLightpush =
          serverSwitchFailsLightpush.peerInfo.toRemotePeerInfo()

      await serverSwitchFailsLightpush.start()

      # When sending an invalid PushRequest
      let publishResponse =
        await client.publish(pubsubTopic, message, serverRemotePeerInfoFailsLightpush)

      # Then the response is negative
      check not publishResponse.isOk()

      if client.reputationManager.isSome:
        check client.reputationManager.get().getReputation(
          serverRemotePeerInfoFailsLightpush.peerId
        ) == some(false)

    asyncTest "Positive Publish To Any":
      # add a peer that supports the Lightpush protocol to the client's PeerManager
      client.peerManager.addPeer(serverRemotePeerInfo) # supports Lightpush

      # When sending a valid PushRequest using publishToAny
      let publishResponse = await client.publishToAny(pubsubTopic, message)

      # Then the response is positive
      check publishResponse.isOk()

    asyncTest "Negative Publish To Any":
      # add a peer that does not support the Lightpush protocol to the client's PeerManager
      client.peerManager.addPeer(serverRemotePeerInfoFailsLightpush)
        # does not support Lightpush

      # When sending a PushRequest using publishToAny to the only peer that doesn't support Lightpush
      let publishResponse = await client.publishToAny(pubsubTopic, message)

      # Then the response is negative
      check not publishResponse.isOk()

    asyncTest "Peer Selection for Lighpush with Reputation":
      # add a peer that does not support the Lightpush protocol to the client's PeerManager
      client.peerManager.addPeer(serverRemotePeerInfoFailsLightpush)

      # try publishing via a failing peer
      let publishResponse1 = await client.publishToAny(pubsubTopic, message)

      check not publishResponse1.isOk()

      if client.reputationManager.isSome:
        client.reputationManager.get().setReputation(serverRemotePeerInfoFailsLightpush.peerId, some(false))

      # add a peer that supports the Lightpush protocol to the client's PeerManager
      client.peerManager.addPeer(serverRemotePeerInfo) # supports Lightpush

      # try publishing again - this time another (good) peer will be selected
      let publishResponse2 = await client.publishToAny(pubsubTopic, message)

      check publishResponse2.isOk()

      if client.reputationManager.isSome:
        client.reputationManager.get().setReputation(serverRemotePeerInfo.peerId, some(true))

      if client.reputationManager.isSome:
        # the reputation of a failed peer is negative
        check client.reputationManager.get().getReputation(
          serverRemotePeerInfoFailsLightpush.peerId
        ) == some(false)

        # the reputation of a successful peer is positive
        check client.reputationManager.get().getReputation(serverRemotePeerInfo.peerId) ==
          some(true)
