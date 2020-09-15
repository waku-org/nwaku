{.used.}

import
  std/unittest,
  chronicles, chronos, stew/shims/net as stewNet, stew/byteutils,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/switch,
  eth/keys,
  ../../waku/protocol/v2/waku_relay,
  ../../waku/node/v2/[wakunode2, waku_types],
  ../test_helpers

procSuite "WakuNode":
  let rng = keys.newRng()
  asyncTest "Message published with content filter is retrievable":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.init(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      pubSubTopic = "chat"
      contentTopic = "foobar"
      contentFilter = ContentFilter(topics: @[contentTopic])
      message = WakuMessage(payload: "hello world".toBytes(),
        contentTopic: contentTopic)

    # This could/should become a more fixed handler (at least default) that
    # would be enforced on WakuNode level.
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        check:
          topic == "chat"
        node.filters.notify(msg[])

    var completionFut = newFuture[bool]()

    # This would be the actual application handler
    proc contentHandler(message: seq[byte]) {.gcsafe, closure.} =
      let msg = string.fromBytes(message)
      check:
        msg == "hello world"
      completionFut.complete(true)

    await node.start()

    # Subscribe our node to the pubSubTopic where all chat data go onto.
    node.subscribe(pubSubTopic, relayHandler)
    # Subscribe a contentFilter to trigger a specific application handler when
    # WakuMessages with that content are received
    node.subscribe(contentFilter, contentHandler)

    node.publish(pubSubTopic, message)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await node.stop()

  asyncTest "Content filtered publishing over network":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      pubSubTopic = "chat"
      contentTopic = "foobar"
      contentFilter = ContentFilter(topics: @[contentTopic])
      message = WakuMessage(payload: "hello world".toBytes(),
        contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    # This could/should become a more fixed handler (at least default) that
    # would be enforced on WakuNode level.
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        check:
          topic == "chat"
        node1.filters.notify(msg[])

    # This would be the actual application handler
    proc contentHandler1(message: seq[byte]) {.gcsafe, closure.} =
      let msg = string.fromBytes(message)
      check:
        msg == "hello world"
      completionFut.complete(true)

    await allFutures([node1.start(), node2.start()])

    # Subscribe our node to the pubSubTopic where all chat data go onto.
    await node1.subscribe(pubSubTopic, relayHandler)
    # Subscribe a contentFilter to trigger a specific application handler when
    # WakuMessages with that content are received
    await node1.subscribe(contentFilter, contentHandler1)
    # Connect peers by dialing from node2 to node1
    let conn = await node2.switch.dial(node1.peerInfo, WakuRelayCodec)
    node2.publish(pubSubTopic, message)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await allFutures([node1.stop(), node2.stop()])
