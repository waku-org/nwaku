{.used.}

import
  std/[options, sequtils, tempfiles],
  testutils/unittests,
  chronos,
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
  ../../../waku/
    [waku_core/topics/pubsub_topic, node/waku_node, waku_core, node/peer_manager],
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
        # contentTopicFull = "/0/toychat/2/huilong/proto"

      let
        serverHandler = server.subs(contentTopicShort)
        clientHandler = client.subs(contentTopicShort)

      await sleepAsync(FUTURE_TIMEOUT)

      await client.connectToNodes(@[server.switch.peerInfo.toRemotePeerInfo()])
      echo client.wakuRelay.isSubscribed("/waku/2/rs/0/58355")
      echo server.wakuRelay.isSubscribed("/waku/2/rs/0/58355")
      echo client.switch.isConnected(server.switch.peerInfo.toRemotePeerInfo().peerId)
      echo server.switch.isConnected(client.switch.peerInfo.toRemotePeerInfo().peerId)

      # When the client publishes a message
      discard await client.publish(
        some(contentTopicShort),
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
        some(contentTopicShort),
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
