{.used.}

import
  std/unittest,
  chronicles, chronos, stew/shims/net as stewNet, stew/byteutils,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  eth/keys,
  ../../waku/v2/protocol/[waku_relay, waku_message, message_notifier],
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2,
  ../test_helpers

procSuite "WakuNode":
  let rng = keys.newRng()
  asyncTest "Message published with content filter is retrievable":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.init(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      pubSubTopic = "chat"
      contentTopic = ContentTopic(1)
      filterRequest = FilterRequest(topic: pubSubTopic, contentFilters: @[ContentFilter(topics: @[contentTopic])], subscribe: true)
      message = WakuMessage(payload: "hello world".toBytes(),
        contentTopic: contentTopic)

    # This could/should become a more fixed handler (at least default) that
    # would be enforced on WakuNode level.
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        check:
          topic == "chat"
        node.filters.notify(msg.value(), topic)

    var completionFut = newFuture[bool]()

    # This would be the actual application handler
    proc contentHandler(msg: WakuMessage) {.gcsafe, closure.} =
      let message = string.fromBytes(msg.payload)
      check:
        message == "hello world"
      completionFut.complete(true)

    await node.start()

    node.mountRelay()

    # Subscribe our node to the pubSubTopic where all chat data go onto.
    node.subscribe(pubSubTopic, relayHandler)

    # Subscribe a contentFilter to trigger a specific application handler when
    # WakuMessages with that content are received
    await node.subscribe(filterRequest, contentHandler)

    await sleepAsync(2000.millis)

    await node.publish(pubSubTopic, message)

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
      contentTopic = ContentTopic(1)
      filterRequest = FilterRequest(topic: pubSubTopic, contentFilters: @[ContentFilter(topics: @[contentTopic])], subscribe: true)
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
        node1.filters.notify(msg.value(), topic)

    # This would be the actual application handler
    proc contentHandler(msg: WakuMessage) {.gcsafe, closure.} =
      let message = string.fromBytes(msg.payload)
      check:
        message == "hello world"
      completionFut.complete(true)

    await allFutures([node1.start(), node2.start()])

    node1.mountRelay()
    node2.mountRelay()

    node1.mountFilter()
    node2.mountFilter()

    # Subscribe our node to the pubSubTopic where all chat data go onto.
    node1.subscribe(pubSubTopic, relayHandler)
    # Subscribe a contentFilter to trigger a specific application handler when
    # WakuMessages with that content are received
    node1.wakuFilter.setPeer(node2.peerInfo)
    await node1.subscribe(filterRequest, contentHandler)
    await sleepAsync(2000.millis)

    # Connect peers by dialing from node2 to node1
    let conn = await node2.switch.dial(node1.peerInfo.peerId, node1.peerInfo.addrs, WakuRelayCodec)

    # We need to sleep to allow the subscription to go through
    info "Going to sleep to allow subscribe to go through"
    await sleepAsync(2000.millis)

    info "Waking up and publishing"
    await node2.publish(pubSubTopic, message)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop() 
    await node2.stop()

  asyncTest "Store protocol returns expected message":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = ContentTopic(1)
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    node1.mountStore()
    await node2.start()
    node2.mountStore()

    await node2.subscriptions.notify("/waku/2/default-waku/proto", message)

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
      contentTopic = ContentTopic(1)
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    node1.mountFilter()
    await node2.start()
    node2.mountFilter()

    node1.wakuFilter.setPeer(node2.peerInfo)

    proc handler(msg: WakuMessage) {.gcsafe, closure.} =
      check:
        msg == message
      completionFut.complete(true)

    await node1.subscribe(FilterRequest(topic: "/waku/2/default-waku/proto", contentFilters: @[ContentFilter(topics: @[contentTopic])], subscribe: true), handler)

    await sleepAsync(2000.millis)

    await node2.subscriptions.notify("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Messages are correctly relayed":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60003))
      pubSubTopic = "test"
      contentTopic = ContentTopic(1)
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo])
    await node3.connectToNodes(@[node2.peerInfo])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node3.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    await node1.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "Peer info parses correctly":
    ## This is such an important utility function for wakunode2
    ## that it deserves its own test :)
    
    # First test the `happy path` expected case
    let
      addrStr = "/ip4/127.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      peerInfo = parsePeerInfo(addrStr)
    
    check:
      $(peerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(peerInfo.addrs[0][0].tryGet()) == "/ip4/127.0.0.1"
      $(peerInfo.addrs[0][1].tryGet()) == "/tcp/60002"
    
    # Now test some common corner cases
    expect ValueError:
      # gibberish
      discard parsePeerInfo("/p2p/$UCH GIBBER!SH")

    expect ValueError:
      # leading whitespace
      discard parsePeerInfo(" /ip4/127.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc")

    expect ValueError:
      # trailing whitespace
      discard parsePeerInfo("/ip4/127.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc ")

    expect ValueError:
      # invalid IP address
      discard parsePeerInfo("/ip4/127.0.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc")
    
    expect ValueError:
      # no PeerID
      discard parsePeerInfo("/ip4/127.0.0.1/tcp/60002")
    
    expect ValueError:
      # unsupported transport
      discard parsePeerInfo("/ip4/127.0.0.1/udp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc")
