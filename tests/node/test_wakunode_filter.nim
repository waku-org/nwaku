{.used.}

import
  std/[options, tables, sequtils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  os,
  libp2p/[peerstore, crypto/crypto]

import
  waku_core,
  node/peer_manager,
  node/waku_node,
  waku_filter_v2,
  waku_filter_v2/client,
  waku_filter_v2/subscriptions,
  ../testlib/[common, wakucore, wakunode, testasync, futures, testutils]

suite "Waku Filter - End to End":
  var client {.threadvar.}: WakuNode
  var clientPeerId {.threadvar.}: PeerId
  var clientClone {.threadvar.}: WakuNode
  var server {.threadvar.}: WakuNode
  var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
  var pubsubTopic {.threadvar.}: PubsubTopic
  var contentTopic {.threadvar.}: ContentTopic
  var contentTopicSeq {.threadvar.}: seq[ContentTopic]
  var pushHandlerFuture {.threadvar.}: Future[(string, WakuMessage)]
  var messagePushHandler {.threadvar.}: FilterPushHandler

  asyncSetup:
    pushHandlerFuture = newFuture[(string, WakuMessage)]()
    messagePushHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async, closure, gcsafe.} =
      pushHandlerFuture.complete((pubsubTopic, message))

    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    contentTopicSeq = @[DefaultContentTopic]

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(23450))
    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(23451))
    clientClone = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(23451))
      # Used for testing client restarts

    await allFutures(server.start(), client.start())

    await server.mountFilter()
    await client.mountFilterClient()

    client.wakuFilterClient.registerPushHandler(messagePushHandler)
    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    clientPeerId = client.peerInfo.toRemotePeerInfo().peerId

    # Prepare the clone but do not start it
    await clientClone.mountFilterClient()
    clientClone.wakuFilterClient.registerPushHandler(messagePushHandler)

  asyncTeardown:
    await allFutures(client.stop(), clientClone.stop(), server.stop())

  asyncTest "Client Node receives Push from Server Node, via Filter":
    # When a client node subscribes to a filter node
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the subscription is successful
    check:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1
      server.wakuFilter.subscriptions.isSubscribed(clientPeerId)

    # When sending a message to the subscribed content topic
    let msg1 = fakeWakuMessage(contentTopic = contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg1)

    # Then the message is pushed to the client
    require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
    let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic1 == pubsubTopic
      pushedMsg1 == msg1

    # When unsubscribing from the subscription
    let unsubscribeResponse = await client.filterUnsubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the unsubscription is successful
    check:
      unsubscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 0

    # When sending a message to the previously subscribed content topic
    pushHandlerFuture = newPushHandlerFuture() # Clear previous future
    let msg2 = fakeWakuMessage(contentTopic = contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg2)

    # Then the message is not pushed to the client
    check:
      not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

  asyncTest "Client Node can't receive Push from Server Node, via Relay":
    # Given the server node has Relay enabled
    await server.mountRelay()

    # And valid filter subscription
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # When a server node gets a Relay message
    let msg1 = fakeWakuMessage(contentTopic = contentTopic)
    discard await server.publish(some(pubsubTopic), msg1)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))

  asyncTest "Client Node can't subscribe to Server Node without Filter":
    # Given a server node with Relay without Filter
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))

    await server.start()
    await server.mountRelay()

    let serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()

    # When a client node subscribes to the server node
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the subscription is successful
    check (not subscribeResponse.isOk())

  asyncTest "Filter Client Node can receive messages after subscribing and restarting, via Filter":
    # Given a valid filter subscription
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # And the client node reboots
    await client.stop()
    await clientClone.start() # Mimic restart by starting the clone

    # When a message is sent to the subscribed content topic, via Filter; without refreshing the subscription
    let msg = fakeWakuMessage(contentTopic = contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg)

    # Then the message is pushed to the client
    check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == pubsubTopic
      pushedMsg == msg

  asyncTest "Filter Client Node can't receive messages after subscribing and restarting, via Relay":
    await server.mountRelay()

    # Given a valid filter subscription
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # And the client node reboots
    await client.stop()
    await clientClone.start() # Mimic restart by starting the clone

    # When a message is sent to the subscribed content topic, via Relay
    let msg = fakeWakuMessage(contentTopic = contentTopic)
    discard await server.publish(some(pubsubTopic), msg)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))

    # Given the client refreshes the subscription
    let subscribeResponse2 = await clientClone.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    check:
      subscribeResponse2.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # When a message is sent to the subscribed content topic, via Relay
    pushHandlerFuture = newPushHandlerFuture()
    let msg2 = fakeWakuMessage(contentTopic = contentTopic)
    discard await server.publish(some(pubsubTopic), msg2)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))
