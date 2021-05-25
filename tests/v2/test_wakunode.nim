{.used.}

import
  testutils/unittests,
  chronicles, chronos, stew/shims/net as stewNet, stew/byteutils,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  eth/keys,
  ../../waku/v2/protocol/[waku_relay, waku_message, message_notifier],
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../../waku/v2/protocol/waku_lightpush/waku_lightpush,
  ../../waku/v2/node/peer_manager/peer_manager,
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
  
  asyncTest "Can receive filtered messages published on both default and other topics":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
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
    node1.mountRelay()
    node1.mountFilter()

    await node2.start()
    node2.mountRelay()
    node2.mountFilter()
    node2.wakuFilter.setPeer(node1.peerInfo)

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
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
      defaultTopic = "/waku/2/default-waku/proto"
      contentTopic = "defaultCT"
      payload = @[byte 1]
      message = WakuMessage(payload: payload, contentTopic: contentTopic)
      filterRequest = FilterRequest(contentFilters: @[ContentFilter(contentTopic: contentTopic)], subscribe: true)

    await node1.start()
    node1.mountRelay()
    node1.mountFilter()

    await node2.start()
    node2.mountRelay(relayMessages=false) # Do not start WakuRelay or subscribe to any topics
    node2.mountFilter()
    node2.wakuFilter.setPeer(node1.peerInfo)

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

  asyncTest "Store protocol returns expected message":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    node1.mountStore(persistMessages = true)
    await node2.start()
    node2.mountStore(persistMessages = true)

    await node2.subscriptions.notify("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.peerInfo)

    proc storeHandler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages[0] == message
      completionFut.complete(true)

    
    await node1.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic)]), storeHandler)

    
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
      contentTopic = ContentTopic("/waku/2/default-content/proto")
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

    await node1.subscribe(FilterRequest(pubSubTopic: "/waku/2/default-waku/proto", contentFilters: @[ContentFilter(contentTopic: contentTopic)], subscribe: true), handler)

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
      contentTopic = ContentTopic("/waku/2/default-content/proto")
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
  
  asyncTest "filtering relayed messages  using topic validators":
    ## test scenario: 
    ## node1 and node3 set node2 as their relay node
    ## node3 publishes two messages with two different contentTopics but on the same pubsub topic 
    ## node1 is also subscribed  to the same pubsub topic 
    ## node2 sets a validator for the same pubsub topic
    ## only one of the messages gets delivered to  node1 because the validator only validates one of the content topics

    let
      # publisher node
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      # Relay node
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
      # Subscriber
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60003))

      pubSubTopic = "test"
      contentTopic1 = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message1 = WakuMessage(payload: payload, contentTopic: contentTopic1)

      payload2 = "you should not see this message!".toBytes()
      contentTopic2 = ContentTopic("2")
      message2 = WakuMessage(payload: payload2, contentTopic: contentTopic2)

    # start all the nodes
    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo])
    await node3.connectToNodes(@[node2.peerInfo])


    var completionFutValidatorAcc = newFuture[bool]()
    var completionFutValidatorRej = newFuture[bool]()

    proc validator(topic: string, message: messages.Message): Future[ValidationResult] {.async.} =
      ## the validator that only allows messages with contentTopic1 to be relayed
      check:
        topic == pubSubTopic
      let msg = WakuMessage.init(message.data) 
      if msg.isOk():
        # only relay messages with contentTopic1
        if msg.value().contentTopic  == contentTopic1:
          result = ValidationResult.Accept
          completionFutValidatorAcc.complete(true)
        else:
          result = ValidationResult.Reject
          completionFutValidatorRej.complete(true)

    # set a topic validator for pubSubTopic 
    let pb  = PubSub(node2.wakuRelay)
    pb.addValidator(pubSubTopic, validator)

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      debug "relayed pubsub topic:", topic
      let msg = WakuMessage.init(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          # check that only messages with contentTopic1 is relayed (but not contentTopic2)
          val.contentTopic == contentTopic1
      # relay handler is called
      completionFut.complete(true)
  

    node3.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    await node1.publish(pubSubTopic, message1)
    await sleepAsync(2000.millis)
    
    # message2 never gets relayed because of the validator
    await node1.publish(pubSubTopic, message2)
    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(10.seconds)) == true
      # check that validator is called for message1
      (await completionFutValidatorAcc.withTimeout(10.seconds)) == true
      # check that validator is called for message2
      (await completionFutValidatorRej.withTimeout(10.seconds)) == true

    
    await node1.stop()
    await node2.stop()
    await node3.stop()
  
  asyncTest "testing rln-relay with mocked zkp":
    
    let
      # publisher node
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      # Relay node
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
      # Subscriber
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60003))

      pubSubTopic = "defaultTopic"
      contentTopic1 = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message1 = WakuMessage(payload: payload, contentTopic: contentTopic1)

    # start all the nodes
    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])
    node2.addRLNRelayValidator(pubSubTopic)

    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.peerInfo])
    await node3.connectToNodes(@[node2.peerInfo])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        let val = msg.value()
        debug "The received topic:", topic
        if topic == pubSubTopic:
          completionFut.complete(true)


    node3.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    await node1.publish(pubSubTopic, message1, rlnRelayEnabled = true)
    await sleepAsync(2000.millis)


    check:
      (await completionFut.withTimeout(10.seconds)) == true
    
    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "Relay protocol is started correctly":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))

    # Relay protocol starts if mounted after node start

    await node1.start()

    node1.mountRelay()

    check:
      GossipSub(node1.wakuRelay).heartbeatFut.isNil == false

    # Relay protocol starts if mounted before node start

    let
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))

    node2.mountRelay()

    check:
      # Relay has not yet started as node has not yet started
      GossipSub(node2.wakuRelay).heartbeatFut.isNil
    
    await node2.start()

    check:
      # Relay started on node start
      GossipSub(node2.wakuRelay).heartbeatFut.isNil == false
    
    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Lightpush message return success":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60010))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60012))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60013))
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Light node, only lightpush
    await node1.start()
    node1.mountRelay(relayMessages=false) # Mount WakuRelay, but do not start or subscribe to any topics
    node1.mountLightPush()

    # Intermediate node
    await node2.start()
    node2.mountRelay(@[pubSubTopic])
    node2.mountLightPush()

    # Receiving node
    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    discard await node1.peerManager.dialPeer(node2.peerInfo, WakuLightPushCodec)
    await sleepAsync(5.seconds)
    await node3.connectToNodes(@[node2.peerInfo])

    var completionFutLightPush = newFuture[bool]()
    var completionFutRelay = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFutRelay.complete(true)

    node3.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    proc handler(response: PushResponse) {.gcsafe, closure.} =
      debug "push response handler, expecting true"
      check:
        response.isSuccess == true
      completionFutLightPush.complete(true)

    # Publishing with lightpush
    await node1.lightpush(pubSubTopic, message, handler)
    await sleepAsync(2000.millis)

    check:
      (await completionFutRelay.withTimeout(5.seconds)) == true
      (await completionFutLightPush.withTimeout(5.seconds)) == true

    await allFutures([node1.stop(), node2.stop(), node3.stop()])
