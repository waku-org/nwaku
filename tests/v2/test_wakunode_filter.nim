{.used.}

import
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto
import
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/waku_node,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/utils/peers,
  ./testlib/common,
  ./testlib/waku2


suite "WakuNode - Filter":

  asyncTest "subscriber should receive the message handled by the publisher":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = WakuNode.new(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = WakuNode.new(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    await allFutures(server.start(), client.start())

    await server.mountFilter()
    await client.mountFilterClient()

    ## Given
    let serverPeerInfo = server.peerInfo.toRemotePeerInfo()

    let
      pubSubTopic = DefaultPubsubTopic
      contentTopic = DefaultContentTopic
      message = fakeWakuMessage(contentTopic=contentTopic)

    var filterPushHandlerFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc filterPushHandler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.gcsafe, closure.} =
      filterPushHandlerFut.complete((pubsubTopic, msg))

    ## When
    await client.filterSubscribe(pubsubTopic, contentTopic, filterPushHandler, peer=serverPeerInfo)

    # Wait for subscription to take effect
    await sleepAsync(100.millis)

    await server.filterHandleMessage(pubSubTopic, message)

    require await filterPushHandlerFut.withTimeout(5.seconds)

    ## Then
    check filterPushHandlerFut.completed()
    let (filterPubsubTopic, filterMessage) = filterPushHandlerFut.read()
    check:
      filterPubsubTopic == pubsubTopic
      filterMessage == message

    ## Cleanup
    await allFutures(client.stop(), server.stop())
