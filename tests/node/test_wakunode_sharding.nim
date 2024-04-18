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
      let topic = "/waku/2/rs/0/1"

      let
        serverHandler = server.subscribeCompletionHandler(topic)
        clientHandler = client.subscribeCompletionHandler(topic)

      await sleepAsync(FUTURE_TIMEOUT)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

      # When the client publishes a message
      discard await client.publish(
        some(topic),
        WakuMessage(payload: "message1".toBytes(), contentTopic: "contentTopic"),
      )
      let
        serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the server receives the message
      assertResultOk(serverResult1)
      assertResultOk(clientResult1)

      # When the server publishes a message
      serverHandler.reset()
      clientHandler.reset()
      discard await server.publish(
        some(topic),
        WakuMessage(payload: "message2".toBytes(), contentTopic: "contentTopic"),
      )
      let
        serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the client receives the message
      assertResultOk(serverResult2)
      assertResultOk(clientResult2)

    asyncTest "Exclusion of Non-Subscribed Service Nodes":
      let
        topic1 = "/waku/2/rs/0/1"
        topic2 = "/waku/2/rs/0/2"

      var
        serverHandler = server.subscribeCompletionHandler(topic1)
        clientHandler = client.subscribeCompletionHandler(topic2)

      await sleepAsync(FUTURE_TIMEOUT)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

      # When the client publishes a message
      discard await client.publish(
        some(topic1),
        WakuMessage(payload: "message1".toBytes(), contentTopic: "contentTopic"),
      )
      let
        serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the server receives the message
      assertResultOk(serverResult1)
      check clientResult1.isErr()

      # When the server publishes a message
      serverHandler.reset()
      clientHandler.reset()
      let wakuMessage2 =
        WakuMessage(payload: "message2".toBytes(), contentTopic: "contentTopic")
      discard await server.publish(some(topic2), wakuMessage2)
      let
        serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the client receives the message
      check serverResult2.isErr()
      assertResultOk(clientResult2)

  suite "Automatic Sharding Mechanics":
    # contentTopicFull2 = "/0/toychat2/2/huilong/proto"

    asyncTest "Content Topic-Based Shard Dialing":
      let
        contentTopicShort = "/toychat/2/huilong/proto"
        contentTopicFull = "/0/toychat/2/huilong/proto"
        pubsubTopic = "/waku/2/rs/0/58355"
          # Automatically generated from the contentTopic above

      let
        serverHandler = server.subscribeToContentTopicWithHandler(contentTopicShort)
        clientHandler = client.subscribeToContentTopicWithHandler(contentTopicShort)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

      # When the client publishes a message
      discard await client.publish(
        some(pubsubTopic),
        WakuMessage(payload: "message1".toBytes(), contentTopic: contentTopicShort),
      )
      let
        serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT_LONG)
        clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT_LONG)

      # Then the server receives the message
      assertResultOk(serverResult1)
      assertResultOk(clientResult1)

      # When the server publishes a message
      serverHandler.reset()
      clientHandler.reset()
      discard await server.publish(
        some(pubsubTopic),
        WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopicShort),
      )
      let
        serverResult2 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
        clientResult2 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

      # Then the client receives the message
      assertResultOk(serverResult2)
      assertResultOk(clientResult2)

    asyncTest "Exclusion of Irrelevant Autosharded Topics":
      discard

  suite "Application Layer Integration":
    suite "App Protocol Compatibility":
      asyncTest "relay":
        let
          topic = "/waku/2/rs/0/1"
          serverHandler = server.subscribeCompletionHandler(topic)
          clientHandler = client.subscribeCompletionHandler(topic)

        await sleepAsync(FUTURE_TIMEOUT)
        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When the client publishes a message
        discard await client.publish(
          some(topic),
          WakuMessage(payload: "message1".toBytes(), contentTopic: "contentTopic"),
        )
        let
          serverResult1 = await serverHandler.waitForResult(FUTURE_TIMEOUT)
          clientResult1 = await clientHandler.waitForResult(FUTURE_TIMEOUT)

        # Then the server receives the message
        assertResultOk(serverResult1)
        assertResultOk(clientResult1)

      asyncTest "filter":
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

        # When the client publishes a message
        let msg = WakuMessage(payload: "message".toBytes(), contentTopic: contentTopic)
        await server.filterHandleMessage(pubsubTopic, msg)

        let pushHandlerResult = await pushHandlerFuture.waitForResult(FUTURE_TIMEOUT)
        assertResultOk(pushHandlerResult)

      asyncTest "lightpush":
        client.mountLightPushClient()
        await server.mountLightpush()

        let
          topic = "/waku/2/rs/0/1"
          clientHandler = client.subscribeCompletionHandler(topic)

        await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])

        # When the client publishes a message
        let
          msg =
            WakuMessage(payload: "message".toBytes(), contentTopic: "myContentTopic")
          lightpublishRespnse = await client.lightpushPublish(
            some(topic), msg, server.switch.peerInfo.toRemotePeerInfo()
          )

        let clientResult = await clientHandler.waitForResult(FUTURE_TIMEOUT)
        assertResultOk(clientResult)
        echo clientResult.get()
