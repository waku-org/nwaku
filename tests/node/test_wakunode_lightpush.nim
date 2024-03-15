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
  ../../../waku/[
    waku_core,
    node/peer_manager,
    node/waku_node,
    waku_filter_v2,
    waku_filter_v2/client,
    waku_filter_v2/subscriptions,
    waku_lightpush,
    waku_lightpush/common,
    waku_lightpush/client,
    waku_lightpush/protocol_metrics,
    waku_lightpush/rpc,
  ],
  ../testlib/[assertions, common, wakucore, wakunode, testasync, futures, testutils]

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
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(server.start(), client.start())
    await server.start()

    waitFor server.mountRelay()
    waitFor server.mountLightpush()
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
        newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      lightpushClient.mountLightpushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.lightpushPublish(
        some(pubsubTopic), message, serverRemotePeerInfo
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is relayed to the server
      assertResultOk publishResponse
