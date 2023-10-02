{.used.}  

import
  std/[options, tables, sequtils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  os,
  libp2p/peerstore,
  libp2p/crypto/crypto

import
  ../../../waku/waku_core,
  ../../../waku/node/peer_manager,
  ../../../waku/node/waku_node,
  ../../../waku/waku_filter_v2,
  ../../../waku/waku_filter_v2/client,
  ../../../waku/waku_filter_v2/subscriptions,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/testasync,
  ../testlib/futures

let FUTURE_TIMEOUT = 1.seconds

suite "Waku Filter - End to End":
  var client {.threadvar.}: WakuNode
  var clientPeerId {.threadvar.}: PeerId
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

    server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    waitFor allFutures(server.start(), client.start())

    waitFor server.mountFilter()
    waitFor client.mountFilterClient()

    client.wakuFilterClient.registerPushHandler(messagePushHandler)
    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    clientPeerId = client.peerInfo.toRemotePeerInfo().peerId

  asyncTeardown:
    waitFor allFutures(client.stop(), server.stop())

  asyncTest "Client Node receives Push from Server Node, via Filter":
    # When a client node subscribes to a filter node
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the subscription is successful
    check:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.len == 1
      server.wakuFilter.subscriptions.hasKey(clientPeerId)

    # When sending a message to the subscribed content topic
    let msg1 = fakeWakuMessage(contentTopic=contentTopic)
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
      server.wakuFilter.subscriptions.len == 0

    # When sending a message to the previously subscribed content topic
    pushHandlerFuture = newPushHandlerFuture() # Clear previous future
    let msg2 = fakeWakuMessage(contentTopic=contentTopic)
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
      server.wakuFilter.subscriptions.len == 1

    # When a server node gets a Relay message
    let msg1 = fakeWakuMessage(contentTopic=contentTopic)
    await server.publish(some(pubsubTopic), msg1)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))

  asyncTest "Client Node can't subscribe to Server Node without Filter":
    # Given a server node with Relay without Filter
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    
    waitFor server.start()
    waitFor server.mountRelay()

    let serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()

    # When a client node subscribes to the server node
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the subscription is successful
    check (not subscribeResponse.isOk())

  asyncTest "Filter Client Node can receive messages after subscribing and stopping without unsubscribing, via Filter":    
    # Given a valid filter subscription
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.len == 1
    
    # And the client node reboots
    waitFor client.stop()
    waitFor client.start()
    client.mountFilterClient()

    # When a message is sent to the subscribed content topic, via Filter; without refreshing the subscription
    let msg1 = fakeWakuMessage(contentTopic=contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg1)

    # Then the message is not pushed to the client
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))

    # Given the client refreshes the subscription
    # TODO: CHECK IF THIS IS NECESSARY. 
    # AT FIRST GLANCE IT SEEMS TO COLLIDE WITH WAKU_FILTER_CLIENT'S BEHAVIOUR: SHOULD NOT NEED?
    let subscribeResponse2 = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    check:
      subscribeResponse2.isOk()
      server.wakuFilter.subscriptions.len == 1

    # When a message is sent to the subscribed content topic, via Filter
    pushHandlerFuture = newPushHandlerFuture() # Clear previous future
    let msg2 = fakeWakuMessage(contentTopic=contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg2)

    # Then the message is pushed to the client
    check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == pubsubTopic
      pushedMsg == msg2

  asyncTest "Filter Client Node can't receive messages after subscribing and stopping without unsubscribing, via Relay":    # Given the server node has Relay enabled
    await server.mountRelay()

    # Given a valid filter subscription
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.len == 1
      
    # And the client node reboots
    waitFor client.stop()
    waitFor client.start()
    client.mountFilterClient()

    # And refreshes the subscription
    # TODO: CHECK IF THIS IS NECESSARY. 
    # AT FIRST GLANCE IT SEEMS TO COLLIDE WITH WAKU_FILTER_CLIENT'S BEHAVIOUR
    let subscribeResponse2 = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    check:
      subscribeResponse2.isOk()
      server.wakuFilter.subscriptions.len == 1

    # When a message is sent to the subscribed content topic, via Relay
    let msg = fakeWakuMessage(contentTopic=contentTopic)
    await server.publish(some(pubsubTopic), msg)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))
