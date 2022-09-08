{.used.}

import
  stew/byteutils, 
  stew/shims/net as stewNet, 
  testutils/unittests,
  chronicles,
  chronos, 
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  eth/keys
import
  ../../waku/v2/protocol/[waku_relay, waku_message],
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2


procSuite "WakuNode - Filter":
  let rng = keys.newRng()
 
  asyncTest "Message published with content filter is retrievable":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      pubSubTopic = "chat"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      filterRequest = FilterRequest(pubSubTopic: pubSubTopic, contentFilters: @[ContentFilter(contentTopic: contentTopic)], subscribe: true)
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
    await node.mountRelay()

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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
    let
      pubSubTopic = "chat"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      filterRequest = FilterRequest(pubSubTopic: pubSubTopic, contentFilters: @[ContentFilter(contentTopic: contentTopic)], subscribe: true)
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

    await node1.mountRelay()
    await node2.mountRelay()

    await node1.mountFilter()
    await node2.mountFilter()

    # Subscribe our node to the pubSubTopic where all chat data go onto.
    node1.subscribe(pubSubTopic, relayHandler)
    # Subscribe a contentFilter to trigger a specific application handler when
    # WakuMessages with that content are received
    node1.wakuFilter.setPeer(node2.switch.peerInfo.toRemotePeerInfo())
    await node1.subscribe(filterRequest, contentHandler)
    await sleepAsync(2000.millis)

    # Connect peers by dialing from node2 to node1
    discard await node2.switch.dial(node1.switch.peerInfo.peerId, node1.switch.peerInfo.addrs, WakuRelayCodec)

    # We need to sleep to allow the subscription to go through
    info "Going to sleep to allow subscribe to go through"
    await sleepAsync(2000.millis)

    info "Waking up and publishing"
    await node2.publish(pubSubTopic, message)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop() 
    await node2.stop()
  
  asyncTest "Can receive filtered messages published on both default and other topics":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
      defaultTopic = "/waku/2/default-waku/proto"
      otherTopic = "/non/waku/formatted"
      defaultContentTopic = "defaultCT"
      otherContentTopic = "otherCT"
      defaultPayload = @[byte 1]
      otherPayload = @[byte 9]
      defaultMessage = WakuMessage(payload: defaultPayload, contentTopic: defaultContentTopic)
      otherMessage = WakuMessage(payload: otherPayload, contentTopic: otherContentTopic)
      defaultFR = FilterRequest(contentFilters: @[ContentFilter(contentTopic: defaultContentTopic)], subscribe: true)
      otherFR = FilterRequest(contentFilters: @[ContentFilter(contentTopic: otherContentTopic)], subscribe: true)

    await node1.start()
    await node1.mountRelay()
    await node1.mountFilter()

    await node2.start()
    await node2.mountRelay()
    await node2.mountFilter()
    node2.wakuFilter.setPeer(node1.switch.peerInfo.toRemotePeerInfo())

    var defaultComplete = newFuture[bool]()
    var otherComplete = newFuture[bool]()

    # Subscribe nodes 1 and 2 to otherTopic
    proc emptyHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      # Do not notify filters or subscriptions here. This should be default behaviour for all topics
      discard
    
    node1.subscribe(otherTopic, emptyHandler)
    node2.subscribe(otherTopic, emptyHandler)

    await sleepAsync(2000.millis)

    proc defaultHandler(msg: WakuMessage) {.gcsafe, closure.} =
      check:
        msg.payload == defaultPayload
        msg.contentTopic == defaultContentTopic
      defaultComplete.complete(true)
    
    proc otherHandler(msg: WakuMessage) {.gcsafe, closure.} =
      check:
        msg.payload == otherPayload
        msg.contentTopic == otherContentTopic
      otherComplete.complete(true)

    # Subscribe a contentFilter to trigger a specific application handler when
    # WakuMessages with that content are received
    await node2.subscribe(defaultFR, defaultHandler)

    await sleepAsync(2000.millis)

    # Let's check that content filtering works on the default topic
    await node1.publish(defaultTopic, defaultMessage)

    check:
      (await defaultComplete.withTimeout(5.seconds)) == true

    # Now check that content filtering works on other topics
    await node2.subscribe(otherFR, otherHandler)

    await sleepAsync(2000.millis)

    await node1.publish(otherTopic,otherMessage)
    
    check:
      (await otherComplete.withTimeout(5.seconds)) == true

    await node1.stop()
    await node2.stop()
  
  asyncTest "Filter protocol works on node without relay capability":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
      defaultTopic = "/waku/2/default-waku/proto"
      contentTopic = "defaultCT"
      payload = @[byte 1]
      message = WakuMessage(payload: payload, contentTopic: contentTopic)
      filterRequest = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], subscribe: true)

    await node1.start()
    await node1.mountRelay()
    await node1.mountFilter()

    await node2.start()
    await node2.mountFilter()
    node2.wakuFilter.setPeer(node1.switch.peerInfo.toRemotePeerInfo())

    check:
      node1.wakuRelay.isNil == false # Node1 is a full node
      node2.wakuRelay.isNil == true # Node 2 is a light node

    var completeFut = newFuture[bool]()

    proc filterHandler(msg: WakuMessage) {.gcsafe, closure.} =
      check:
        msg.payload == payload
        msg.contentTopic == contentTopic
      completeFut.complete(true)

    # Subscribe a contentFilter to trigger a specific application handler when
    # WakuMessages with that content are received
    await node2.subscribe(filterRequest, filterHandler)

    await sleepAsync(2000.millis)

    # Let's check that content filtering works on the default topic
    await node1.publish(defaultTopic, message)

    check:
      (await completeFut.withTimeout(5.seconds)) == true

    await node1.stop()
    await node2.stop()

  asyncTest "Filter protocol returns expected message":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    await node1.mountFilter()
    await node2.start()
    await node2.mountFilter()

    node1.wakuFilter.setPeer(node2.switch.peerInfo.toRemotePeerInfo())

    proc handler(msg: WakuMessage) {.gcsafe, closure.} =
      check:
        msg == message
      completionFut.complete(true)

    await node1.subscribe(FilterRequest(pubSubTopic: "/waku/2/default-waku/proto", contentFilters: @[ContentFilter(contentTopic: contentTopic)], subscribe: true), handler)

    await sleepAsync(2000.millis)

    await node2.wakuFilter.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()
