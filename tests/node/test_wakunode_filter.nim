{.used.}

import
  std/sequtils,
  std/options,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import
  std/[options, tables, sequtils],
  testutils/unittests,
  chronos,
  chronicles,
  os,
  libp2p/peerstore

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

suite "Full Node - Waku Filter - End to End":
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

  asyncTest "Full Client Node to Full Service Node Subscription":
    # When a full client node subscribes to a full service node
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
