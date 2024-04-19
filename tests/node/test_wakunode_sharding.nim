{.used.}

import
  std/[options, sequtils, tempfiles],
  testutils/unittests,
  chronos,
  chronicles,
  stew/shims/net as stewNet

import
  std/[sequtils, tempfiles],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub

import
  ../../../waku/[
    waku_core/topics/pubsub_topic,
    node/waku_node,
    waku_core,
    node/peer_manager,
    waku_filter_v2/client,
  ],
  ../waku_relay/utils,
  ../testlib/[assertions, common, wakucore, wakunode, testasync, futures]

import ../../../waku/waku_relay/protocol

const
  listenIp = ValidIpAddress.init("0.0.0.0")
  listenPort = Port(0)

suite "Sharding":
  var
    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode

  asyncSetup:
    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, listenIp, listenPort)
    client = newTestWakuNode(clientKey, listenIp, listenPort)

    await allFutures(server.mountRelay(), client.mountRelay())
    await allFutures(server.start(), client.start())

  asyncTeardown:
    await allFutures(server.stop(), client.stop())

  suite "Static Sharding Functionality":
    asyncTest "Shard Subscription and Peer Dialing":
      # Given a connected server and client subscribed to the same pubsub shard
      let
        topic = "/waku/2/rs/0/1"
        serverHandler = server.subscribeCompletionHandler(topic)
        clientHandler = client.subscribeCompletionHandler(topic)

      # await sleepAsync(FUTURE_TIMEOUT)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

      # When the client publishes a message in the subscribed topic
      discard await client.publish(
        some(topic),
        WakuMessage(payload: "message1".toBytes(), contentTopic: "contentTopic"),
      )

      # Then the server receives the message
      let
        serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      assertResultOk(serverResult1)
      assertResultOk(clientResult1)

      # When the server publishes a message in the subscribed topic
      serverHandler.reset()
      clientHandler.reset()
      discard await server.publish(
        some(topic),
        WakuMessage(payload: "message2".toBytes(), contentTopic: "contentTopic"),
      )

      # Then the client receives the message
      let
        serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      assertResultOk(serverResult2)
      assertResultOk(clientResult2)

    asyncTest "Exclusion of Non-Subscribed Service Nodes":
      # When a connected server and client are subscribed to different pubsub shards
      let
        topic1 = "/waku/2/rs/0/1"
        topic2 = "/waku/2/rs/0/2"
        contentTopic = "myContentTopic"

      var
        serverHandler = server.subscribeCompletionHandler(topic1)
        clientHandler = client.subscribeCompletionHandler(topic2)

      await sleepAsync(FUTURE_TIMEOUT)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

      # When a message is published in the server's subscribed topic
      discard await client.publish(
        some(topic1),
        WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopic),
      )
      let
        serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the server receives the message but the client does not
      assertResultOk(serverResult1)
      check clientResult1.isErr()

      # When the server publishes a message in the client's subscribed topic
      serverHandler.reset()
      clientHandler.reset()
      let wakuMessage2 =
        WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopic)
      discard await server.publish(some(topic2), wakuMessage2)
      let
        serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the client receives the message but the server does not
      check serverResult2.isErr()
      assertResultOk(clientResult2)

  suite "Automatic Sharding Mechanics":
    asyncTest "Content Topic-Based Shard Dialing":
      # Given a connected server and client subscribed to the same content topic (with two different formats)
      let
        contentTopicShort = "/toychat/2/huilong/proto"
        contentTopicFull = "/0/toychat/2/huilong/proto"
        pubsubTopic = "/waku/2/rs/0/58355"
          # Automatically generated from the contentTopic above

      let
        serverHandler = server.subscribeToContentTopicWithHandler(contentTopicShort)
        clientHandler = client.subscribeToContentTopicWithHandler(contentTopicFull)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

      # When the client publishes a message
      discard await client.publish(
        some(pubsubTopic),
        WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopicShort),
      )
      let
        serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT_LONG)
        clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT_LONG)

      # Then the server and client receive the message
      assertResultOk(serverResult1)
      assertResultOk(clientResult1)

      # When the server publishes a message
      serverHandler.reset()
      clientHandler.reset()
      discard await server.publish(
        some(pubsubTopic),
        WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopicFull),
      )
      let
        serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the client and server receive the message
      assertResultOk(serverResult2)
      assertResultOk(clientResult2)

    asyncTest "Exclusion of Irrelevant Autosharded Topics":
      # Given a connected server and client subscribed to different content topics
      let
        contentTopic1 = "/toychat/2/huilong/proto"
        pubsubTopic1 = "/waku/2/rs/0/58355"
          # Automatically generated from the contentTopic above
        contentTopic2 = "/0/toychat2/2/huilong/proto"
        pubsubTopic2 = "/waku/2/rs/0/23286"
          # Automatically generated from the contentTopic above

      let
        serverHandler = server.subscribeToContentTopicWithHandler(contentTopic1)
        clientHandler = client.subscribeToContentTopicWithHandler(contentTopic2)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

      # When the server publishes a message in the server's subscribed topic
      discard await server.publish(
        some(pubsubTopic1),
        WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopic1),
      )
      let
        serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the server receives the message but the client does not
      assertResultOk(serverResult1)
      check clientResult1.isErr()

      # When the client publishes a message in the client's subscribed topic
      serverHandler.reset()
      clientHandler.reset()
      discard await client.publish(
        some(pubsubTopic2),
        WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopic2),
      )
      let
        serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT_LONG)
        clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT_LONG)

      # Then the client receives the message but the server does not
      assertResultOk(clientResult2)
      check serverResult2.isErr()

  suite "Application Layer Integration":
    suite "App Protocol Compatibility":
      asyncTest "relay":
        # Given a connected server and client subscribed to the same pubsub topic
        let
          pubsubTopic = "/waku/2/rs/0/1"
          serverHandler = server.subscribeCompletionHandler(pubsubTopic)
          clientHandler = client.subscribeCompletionHandler(pubsubTopic)

        await sleepAsync(FUTURE_TIMEOUT)
        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When the client publishes a message
        discard await client.publish(
          some(pubsubTopic),
          WakuMessage(payload: "message1".toBytes(), contentTopic: "myContentTopic"),
        )
        let
          serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
          clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

        # Then the server and client receive the message
        assertResultOk(serverResult1)
        assertResultOk(clientResult1)

      asyncTest "filter":
        # Given a connected server and client using the same pubsub topic
        await client.mountFilterClient()
        await server.mountFilter()

        let pushHandlerFuture = newFuture[(string, WakuMessage)]()
        proc messagePushHandler(
            pubsubTopic: PubsubTopic, message: WakuMessage
        ): Future[void] {.async, closure, gcsafe.} =
          pushHandlerFuture.complete((pubsubTopic, message))

        client.wakuFilterClient.registerPushHandler(messagePushHandler)
        let
          pubsubTopic = "/waku/2/rs/0/1"
          contentTopic = "myContentTopic"
          subscribeResponse = await client.filterSubscribe(
            some(pubsubTopic),
            @[contentTopic],
            server.switch.peerInfo.toRemotePeerInfo(),
          )

        assertResultOk(subscribeResponse)
        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When a peer publishes a message (the client, for testing easeness)
        let msg = WakuMessage(payload: "message".toBytes(), contentTopic: contentTopic)
        await server.filterHandleMessage(pubsubTopic, msg)

        # Then the client receives the message
        let pushHandlerResult = await pushHandlerFuture.waitForResult(FUTURE_TIMEOUT)
        assertResultOk(pushHandlerResult)

      asyncTest "lightpush":
        # Given a connected server and client subscribed to the same pubsub topic
        client.mountLightPushClient()
        await server.mountLightpush()

        let
          topic = "/waku/2/rs/0/1"
          clientHandler = client.subscribeCompletionHandler(topic)

        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When a peer publishes a message (the client, for testing easeness)
        let
          msg =
            WakuMessage(payload: "message".toBytes(), contentTopic: "myContentTopic")
          lightpublishRespnse = await client.lightpushPublish(
            some(topic), msg, server.switch.peerInfo.toRemotePeerInfo()
          )

        # Then the client receives the message
        let clientResult = await clientHandler.waitForResult(FUTURE_TIMEOUT)
        assertResultOk(clientResult)

    suite "Content Topic Filtering and Routing":
      asyncTest "relay (content topic filtering)":
        # Given a connected server and client subscribed to the same content topic (with two different formats)
        let
          contentTopicShort = "/toychat/2/huilong/proto"
          contentTopicFull = "/0/toychat/2/huilong/proto"
          pubsubTopic = "/waku/2/rs/0/58355"
          serverHandler = server.subscribeToContentTopicWithHandler(contentTopicShort)
          clientHandler = client.subscribeToContentTopicWithHandler(contentTopicFull)

        await sleepAsync(FUTURE_TIMEOUT)
        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When the client publishes a message
        discard await client.publish(
          some(pubsubTopic),
          WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopicShort),
        )
        let
          serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
          clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

        # Then the server and client receive the message
        assertResultOk(serverResult1)
        assertResultOk(clientResult1)

        # When the server publishes a message
        serverHandler.reset()
        clientHandler.reset()
        discard await server.publish(
          some(pubsubTopic),
          WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopicFull),
        )
        let
          serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
          clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

        # Then the server and client receive the message
        assertResultOk(serverResult2)
        assertResultOk(clientResult2)

      asyncTest "filter (content topic filtering)":
        # Given a connected server and client using the same content topic (with two different formats)
        await client.mountFilterClient()
        await server.mountFilter()

        let pushHandlerFuture = newFuture[(string, WakuMessage)]()
        proc messagePushHandler(
            pubsubTopic: PubsubTopic, message: WakuMessage
        ): Future[void] {.async, closure, gcsafe.} =
          pushHandlerFuture.complete((pubsubTopic, message))

        client.wakuFilterClient.registerPushHandler(messagePushHandler)
        let
          contentTopicShort = "/toychat/2/huilong/proto"
          contentTopicFull = "/0/toychat/2/huilong/proto"
          pubsubTopic = "/waku/2/rs/0/58355"
          subscribeResponse1 = await client.filterSubscribe(
            some(pubsubTopic),
            @[contentTopicShort],
            server.switch.peerInfo.toRemotePeerInfo(),
          )

        assertResultOk(subscribeResponse1)
        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When the client publishes a message
        let msg =
          WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopicShort)
        await server.filterHandleMessage(pubsubTopic, msg)

        # Then the client receives the message
        let pushHandlerResult = await pushHandlerFuture.waitForResult(FUTURE_TIMEOUT)
        assertResultOk(pushHandlerResult)
        check pushHandlerResult.get() == (pubsubTopic, msg)

        # Given the subscription is cleared and a new subscription is made
        let
          unsubscribeResponse =
            await client.filterUnsubscribeAll(server.switch.peerInfo.toRemotePeerInfo())
          subscribeResponse2 = await client.filterSubscribe(
            some(pubsubTopic),
            @[contentTopicFull],
            server.switch.peerInfo.toRemotePeerInfo(),
          )

        assertResultOk(unsubscribeResponse)
        assertResultOk(subscribeResponse2)

        # When the client publishes a message
        pushHandlerFuture.reset()
        let msg2 =
          WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopicFull)
        await server.filterHandleMessage(pubsubTopic, msg2)

        # Then the client receives the message
        let pushHandlerResult2 = await pushHandlerFuture.waitForResult(FUTURE_TIMEOUT)
        assertResultOk(pushHandlerResult2)
        check pushHandlerResult2.get() == (pubsubTopic, msg2)

      asyncTest "lightpush (content topic filtering)":
        # Given a connected server and client using the same content topic (with two different formats)
        client.mountLightPushClient()
        await server.mountLightpush()

        let
          contentTopicShort = "/toychat/2/huilong/proto"
          contentTopicFull = "/0/toychat/2/huilong/proto"
          pubsubTopic = "/waku/2/rs/0/58355"
          clientHandler = client.subscribeToContentTopicWithHandler(contentTopicShort)

        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When a peer publishes a message (the client, for testing easeness)
        let
          msg =
            WakuMessage(payload: "message".toBytes(), contentTopic: contentTopicFull)
          lightpublishRespnse = await client.lightpushPublish(
            some(pubsubTopic), msg, server.switch.peerInfo.toRemotePeerInfo()
          )

        # Then the client receives the message
        let clientResult = await clientHandler.waitForResult(FUTURE_TIMEOUT)
        assertResultOk(clientResult)

      asyncTest "exclusion - relay (content topic filtering)":
        # Given a connected server and client subscribed to different content topics
        let
          contentTopic1 = "/toychat/2/huilong/proto"
          pubsubTopic1 = "/waku/2/rs/0/58355"
            # Automatically generated from the contentTopic above
          contentTopic2 = "/0/toychat2/2/huilong/proto"
          pubsubTopic2 = "/waku/2/rs/0/23286"
            # Automatically generated from the contentTopic above
          serverHandler = server.subscribeToContentTopicWithHandler(contentTopic1)
          clientHandler = client.subscribeToContentTopicWithHandler(contentTopic2)

        await sleepAsync(FUTURE_TIMEOUT)
        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When the client publishes a message in the client's subscribed topic
        discard await client.publish(
          some(pubsubTopic2),
          WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopic2),
        )
        let
          serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
          clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

        # Then the client receives the message but the server does not
        check serverResult1.isErr()
        assertResultOk(clientResult1)

        # When the server publishes a message in the server's subscribed topic
        serverHandler.reset()
        clientHandler.reset()
        discard await server.publish(
          some(pubsubTopic1),
          WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopic1),
        )
        let
          serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
          clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

        # Then the server receives the message but the client does not
        assertResultOk(serverResult2)
        check clientResult2.isErr()

      asyncTest "exclusion - filter (content topic filtering)":
        # Given a connected server and client using different content topics
        await client.mountFilterClient()
        await server.mountFilter()

        let pushHandlerFuture = newFuture[(string, WakuMessage)]()
        proc messagePushHandler(
            pubsubTopic: PubsubTopic, message: WakuMessage
        ): Future[void] {.async, closure, gcsafe.} =
          pushHandlerFuture.complete((pubsubTopic, message))

        client.wakuFilterClient.registerPushHandler(messagePushHandler)
        let
          contentTopic1 = "/toychat/2/huilong/proto"
          pubsubTopic1 = "/waku/2/rs/0/58355"
            # Automatically generated from the contentTopic above
          contentTopic2 = "/0/toychat2/2/huilong/proto"
          pubsubTopic2 = "/waku/2/rs/0/23286"
            # Automatically generated from the contentTopic above
          subscribeResponse1 = await client.filterSubscribe(
            some(pubsubTopic1),
            @[contentTopic1],
            server.switch.peerInfo.toRemotePeerInfo(),
          )

        assertResultOk(subscribeResponse1)
        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When the server publishes a message in the server's subscribed topic
        let msg =
          WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopic2)
        await server.filterHandleMessage(pubsubTopic2, msg)

        # Then the client does not receive the message
        let pushHandlerResult = await pushHandlerFuture.waitForResult(FUTURE_TIMEOUT)
        check pushHandlerResult.isErr()

      asyncTest "exclusion - lightpush (content topic filtering)":
        # Given a connected server and client using different content topics
        client.mountLightPushClient()
        await server.mountLightpush()

        let
          contentTopic1 = "/toychat/2/huilong/proto"
          pubsubTopic1 = "/waku/2/rs/0/58355"
            # Automatically generated from the contentTopic above
          contentTopic2 = "/0/toychat2/2/huilong/proto"
          pubsubTopic2 = "/waku/2/rs/0/23286"
            # Automatically generated from the contentTopic above
          clientHandler = client.subscribeToContentTopicWithHandler(contentTopic1)

        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When a peer publishes a message in the server's subscribed topic (the client, for testing easeness)
        let
          msg = WakuMessage(payload: "message".toBytes(), contentTopic: contentTopic2)
          lightpublishRespnse = await client.lightpushPublish(
            some(pubsubTopic2), msg, server.switch.peerInfo.toRemotePeerInfo()
          )

        # Then the client does not receive the message
        let clientResult = await clientHandler.waitForResult(FUTURE_TIMEOUT)
        check clientResult.isErr()
