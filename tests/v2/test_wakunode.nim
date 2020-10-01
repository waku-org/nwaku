{.used.}

import
  std/unittest,
  chronicles, chronos, stew/shims/net as stewNet, stew/byteutils,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/switch,
  eth/keys,
  ../../waku/protocol/v2/[waku_relay, waku_store, waku_filter, message_notifier],
  ../../waku/node/v2/[wakunode2, waku_types],
  ../test_helpers

procSuite "WakuNode":
  let rng = keys.newRng()
  asyncTest "Store protocol returns expected message":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = "foobar"
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    await node2.start()

    await node2.subscriptions.notify("waku", message)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.peerInfo)

    proc storeHandler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages[0] == message
      completionFut.complete(true)

    await node1.query(HistoryQuery(topics: @[contentTopic]), storeHandler)
    
    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Filter protocol returns expected message":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = "foobar"
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    await node2.start()

    node1.wakuFilter.setPeer(node2.peerInfo)

    proc handler(msg: MessagePush) {.gcsafe, closure.} =
      echo msg
      check:
        msg.messages[0] == message
      completionFut.complete(true)

    await node1.subscribe(FilterRequest(topic: "waku", contentFilters: @[ContentFilter(topics: @[contentTopic])]), handler)

    await sleepAsync(2000.millis)

    await node2.subscriptions.notify("waku", message)

    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()
