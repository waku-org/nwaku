{.used.}

import
  std/options,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto
import
  ../../waku/waku_core,
  ../../waku/node/peer_manager,
  ../../waku/waku_node,
  ./testlib/common,
  ./testlib/wakucore,
  ./testlib/wakunode


suite "WakuNode - Filter":

  asyncTest "subscriber should receive the message handled by the publisher":
    ## Setup
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
      clientKey = generateSecp256k1Key()
      client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    waitFor allFutures(server.start(), client.start())

    waitFor server.mountFilter()
    waitFor client.mountFilterClient()

    ## Given
    let serverPeerInfo = server.peerInfo.toRemotePeerInfo()

    let
      pubSubTopic = DefaultPubsubTopic
      contentTopic = DefaultContentTopic
      message = fakeWakuMessage(contentTopic=contentTopic)

    var filterPushHandlerFut = newFuture[(PubsubTopic, WakuMessage)]()
    proc filterPushHandler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe, closure.} =
      filterPushHandlerFut.complete((pubsubTopic, msg))

    ## When
    await client.legacyFilterSubscribe(some(pubsubTopic), contentTopic, filterPushHandler, peer=serverPeerInfo)

    # Wait for subscription to take effect
    waitFor sleepAsync(100.millis)

    waitFor server.filterHandleMessage(pubSubTopic, message)

    require waitFor filterPushHandlerFut.withTimeout(5.seconds)

    ## Then
    check filterPushHandlerFut.completed()
    let (filterPubsubTopic, filterMessage) = filterPushHandlerFut.read()
    check:
      filterPubsubTopic == pubsubTopic
      filterMessage == message

    ## Cleanup
    waitFor allFutures(client.stop(), server.stop())
