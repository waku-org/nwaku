{.used.}

import
  testutils/unittests,
  std/sequtils,
  chronicles, chronos, stew/shims/net as stewNet, stew/byteutils, std/os,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  eth/keys,
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/node/storage/message/waku_message_store,
  ../../waku/v2/protocol/[waku_relay, waku_message],
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../../waku/v2/protocol/waku_lightpush/waku_lightpush,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2,
  ../test_helpers

when defined(rln):
  import 
    ../../waku/v2/protocol/waku_rln_relay/[waku_rln_relay_utils, waku_rln_relay_types]
  from times import epochTime
  
const RLNRELAY_PUBSUB_TOPIC = "waku/2/rlnrelay/proto"
template sourceDir: string = currentSourcePath.parentDir()
const KEY_PATH = sourceDir / "resources/test_key.pem"
const CERT_PATH = sourceDir / "resources/test_cert.pem"

procSuite "WakuNode":
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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
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
    node1.wakuFilter.setPeer(node2.switch.peerInfo.toRemotePeerInfo())
    await node1.subscribe(filterRequest, contentHandler)
    await sleepAsync(2000.millis)

    # Connect peers by dialing from node2 to node1
    let conn = await node2.switch.dial(node1.switch.peerInfo.peerId, node1.switch.peerInfo.addrs, WakuRelayCodec)

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
    node1.mountRelay()
    node1.mountFilter()

    await node2.start()
    node2.mountRelay()
    node2.mountFilter()
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
    node1.mountRelay()
    node1.mountFilter()

    await node2.start()
    node2.mountRelay(relayMessages=false) # Do not start WakuRelay or subscribe to any topics
    node2.mountFilter()
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

  asyncTest "Store protocol returns expected message":
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
    node1.mountStore(persistMessages = true)
    await node2.start()
    node2.mountStore(persistMessages = true)

    await node2.wakuStore.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())

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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    var completionFut = newFuture[bool]()

    await node1.start()
    node1.mountFilter()
    await node2.start()
    node2.mountFilter()

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

  asyncTest "Messages are correctly relayed":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
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

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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
  
  asyncTest "Protocol matcher works as expected":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      pubSubTopic = "/waku/2/default-waku/proto"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Setup node 1 with stable codec "/vac/waku/relay/2.0.0"

    await node1.start()
    node1.mountRelay(@[pubSubTopic])
    node1.wakuRelay.codec = "/vac/waku/relay/2.0.0"

    # Setup node 2 with beta codec "/vac/waku/relay/2.0.0-beta2"

    await node2.start()
    node2.mountRelay(@[pubSubTopic])
    node2.wakuRelay.codec = "/vac/waku/relay/2.0.0-beta2"

    check:
      # Check that mounted codecs are actually different
      node1.wakuRelay.codec ==  "/vac/waku/relay/2.0.0"
      node2.wakuRelay.codec == "/vac/waku/relay/2.0.0-beta2"

    # Now verify that protocol matcher returns `true` and relay works

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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

    node2.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    await node1.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Peer info parses correctly":
    ## This is such an important utility function for wakunode2
    ## that it deserves its own test :)
    
    # First test the `happy path` expected case
    let
      addrStr = "/ip4/127.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      remotePeerInfo = parseRemotePeerInfo(addrStr)
    
    check:
      $(remotePeerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(remotePeerInfo.addrs[0][0].tryGet()) == "/ip4/127.0.0.1"
      $(remotePeerInfo.addrs[0][1].tryGet()) == "/tcp/60002"
    
    # Now test some common corner cases
    expect LPError:
      # gibberish
      discard parseRemotePeerInfo("/p2p/$UCH GIBBER!SH")

    expect LPError:
      # leading whitespace
      discard parseRemotePeerInfo(" /ip4/127.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc")

    expect LPError:
      # trailing whitespace
      discard parseRemotePeerInfo("/ip4/127.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc ")

    expect LPError:
      # invalid IP address
      discard parseRemotePeerInfo("/ip4/127.0.0.0.1/tcp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc")
    
    expect LPError:
      # no PeerID
      discard parseRemotePeerInfo("/ip4/127.0.0.1/tcp/60002")
    
    expect ValueError:
      # unsupported transport
      discard parseRemotePeerInfo("/ip4/127.0.0.1/udp/60002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc")
  
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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      # Relay node
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
      # Subscriber
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60003))

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

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])


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
  
  when defined(rln):
    asyncTest "testing rln-relay with valid proof":
    
      let
        # publisher node
        nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
        # Relay node
        nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
        # Subscriber
        nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60003))

        rlnRelayPubSubTopic = RLNRELAY_PUBSUB_TOPIC
        contentTopic = ContentTopic("/waku/2/default-content/proto")

      # set up three nodes
      # node1
      node1.mountRelay(@[rlnRelayPubSubTopic]) 
      let (groupOpt1, memKeyPairOpt1, memIndexOpt1) = rlnRelaySetUp(1) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node1.mountRlnRelay(groupOpt = groupOpt1,
                                  memKeyPairOpt = memKeyPairOpt1, 
                                  memIndexOpt= memIndexOpt1, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node1.start() 

      # node 2
      node2.mountRelay(@[rlnRelayPubSubTopic])
      let (groupOpt2, memKeyPairOpt2, memIndexOpt2) = rlnRelaySetUp(2) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node2.mountRlnRelay(groupOpt = groupOpt2, 
                                  memKeyPairOpt = memKeyPairOpt2, 
                                  memIndexOpt= memIndexOpt2, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node2.start()

      # node 3
      node3.mountRelay(@[rlnRelayPubSubTopic])
      let (groupOpt3, memKeyPairOpt3, memIndexOpt3) = rlnRelaySetUp(3) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node3.mountRlnRelay(groupOpt = groupOpt3, 
                                  memKeyPairOpt = memKeyPairOpt3, 
                                  memIndexOpt= memIndexOpt3, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node3.start()

      # connect them together
      await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
      await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
      
      var completionFut = newFuture[bool]()
      proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        let msg = WakuMessage.init(data)
        if msg.isOk():
          let val = msg.value()
          debug "The received topic:", topic
          if topic == rlnRelayPubSubTopic:
            completionFut.complete(true)

      # mount the relay handler
      node3.subscribe(rlnRelayPubSubTopic, relayHandler)
      await sleepAsync(2000.millis)

      # prepare the message payload
      let payload = "Hello".toBytes()

      # prepare the epoch
      let epoch = getCurrentEpoch()    

      var message = WakuMessage(payload: @payload, 
                                contentTopic: contentTopic)
      doAssert(node1.wakuRlnRelay.appendRLNProof(message, epochTime()))


      ## node1 publishes a message with a rate limit proof, the message is then relayed to node2 which in turn 
      ## verifies the rate limit proof of the message and relays the message to node3
      ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
      await node1.publish(rlnRelayPubSubTopic, message)
      await sleepAsync(2000.millis)


      check:
        (await completionFut.withTimeout(10.seconds)) == true
      
      await node1.stop()
      await node2.stop()
      await node3.stop()
    asyncTest "testing rln-relay with invalid proof":
      let
        # publisher node
        nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
        # Relay node
        nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
        # Subscriber
        nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60003))

        rlnRelayPubSubTopic = RLNRELAY_PUBSUB_TOPIC
        contentTopic = ContentTopic("/waku/2/default-content/proto")

      # set up three nodes
      # node1
      node1.mountRelay(@[rlnRelayPubSubTopic]) 
      let (groupOpt1, memKeyPairOpt1, memIndexOpt1) = rlnRelaySetUp(1) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node1.mountRlnRelay(groupOpt = groupOpt1,
                                  memKeyPairOpt = memKeyPairOpt1, 
                                  memIndexOpt= memIndexOpt1, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node1.start() 

      # node 2
      node2.mountRelay(@[rlnRelayPubSubTopic])
      let (groupOpt2, memKeyPairOpt2, memIndexOpt2) = rlnRelaySetUp(2) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node2.mountRlnRelay(groupOpt = groupOpt2, 
                                  memKeyPairOpt = memKeyPairOpt2, 
                                  memIndexOpt= memIndexOpt2, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node2.start()

      # node 3
      node3.mountRelay(@[rlnRelayPubSubTopic])
      let (groupOpt3, memKeyPairOpt3, memIndexOpt3) = rlnRelaySetUp(3) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node3.mountRlnRelay(groupOpt = groupOpt3, 
                                  memKeyPairOpt = memKeyPairOpt3, 
                                  memIndexOpt= memIndexOpt3, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node3.start()

      # connect them together
      await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
      await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
      
      # define a custom relay handler
      var completionFut = newFuture[bool]()
      proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        let msg = WakuMessage.init(data)
        if msg.isOk():
          let val = msg.value()
          debug "The received topic:", topic
          if topic == rlnRelayPubSubTopic:
            completionFut.complete(true)

      # mount the relay handler
      node3.subscribe(rlnRelayPubSubTopic, relayHandler)
      await sleepAsync(2000.millis)

      # prepare the message payload
      let payload = "Hello".toBytes()

      # prepare the epoch
      let epoch = getCurrentEpoch()

      # prepare the proof
      let 
        contentTopicBytes = contentTopic.toBytes
        input = concat(payload, contentTopicBytes)
        rateLimitProofRes = node1.wakuRlnRelay.rlnInstance.proofGen(data = input, 
                                                                memKeys = node1.wakuRlnRelay.membershipKeyPair, 
                                                                memIndex = MembershipIndex(4), 
                                                                epoch = epoch)
      doAssert(rateLimitProofRes.isOk())
      let rateLimitProof = rateLimitProofRes.value     

      let message = WakuMessage(payload: @payload, 
                                contentTopic: contentTopic,  
                                proof: rateLimitProof)


      ## node1 publishes a message with an invalid rln proof, the message is then relayed to node2 which in turn 
      ## attempts to verify the rate limit proof and fails hence does not relay the message to node3, thus the relayHandler of node3
      ## never gets called
      ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
      await node1.publish(rlnRelayPubSubTopic, message)
      await sleepAsync(2000.millis)

      check:
        # the relayHandler of node3 never gets called
        (await completionFut.withTimeout(10.seconds)) == false
      
      await node1.stop()
      await node2.stop()
      await node3.stop()

    asyncTest "testing rln-relay double-signaling detection":
    
      let
        # publisher node
        nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
        # Relay node
        nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))
        # Subscriber
        nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
        node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60003))

        rlnRelayPubSubTopic = RLNRELAY_PUBSUB_TOPIC
        contentTopic = ContentTopic("/waku/2/default-content/proto")

      # set up three nodes
      # node1
      node1.mountRelay(@[rlnRelayPubSubTopic]) 
      let (groupOpt1, memKeyPairOpt1, memIndexOpt1) = rlnRelaySetUp(1) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node1.mountRlnRelay(groupOpt = groupOpt1,
                                  memKeyPairOpt = memKeyPairOpt1, 
                                  memIndexOpt= memIndexOpt1, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node1.start() 

      # node 2
      node2.mountRelay(@[rlnRelayPubSubTopic])
      let (groupOpt2, memKeyPairOpt2, memIndexOpt2) = rlnRelaySetUp(2) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node2.mountRlnRelay(groupOpt = groupOpt2, 
                                  memKeyPairOpt = memKeyPairOpt2, 
                                  memIndexOpt= memIndexOpt2, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node2.start()

      # node 3
      node3.mountRelay(@[rlnRelayPubSubTopic])
      let (groupOpt3, memKeyPairOpt3, memIndexOpt3) = rlnRelaySetUp(3) # set up rln relay inputs
      # mount rlnrelay in off-chain mode
      waitFor node3.mountRlnRelay(groupOpt = groupOpt3, 
                                  memKeyPairOpt = memKeyPairOpt3, 
                                  memIndexOpt= memIndexOpt3, 
                                  onchainMode = false, 
                                  pubsubTopic = rlnRelayPubSubTopic,
                                  contentTopic = contentTopic)
      await node3.start()

      # connect the nodes together node1 <-> node2 <-> node3
      await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
      await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

      # get the current epoch time 
      let time = epochTime()
      #  create some messages with rate limit proofs
      var 
        wm1 = WakuMessage(payload: "message 1".toBytes(), contentTopic: contentTopic)
        proofAdded1 = node3.wakuRlnRelay.appendRLNProof(wm1, time)
        # another message in the same epoch as wm1, it will break the messaging rate limit
        wm2 = WakuMessage(payload: "message2".toBytes(), contentTopic: contentTopic)
        proofAdded2 = node3.wakuRlnRelay.appendRLNProof(wm2, time)
        #  wm3 points to the next epoch 
        wm3 = WakuMessage(payload: "message 3".toBytes(), contentTopic: contentTopic)
        proofAdded3 = node3.wakuRlnRelay.appendRLNProof(wm3, time+EPOCH_UNIT_SECONDS)
        wm4 = WakuMessage(payload: "message4".toBytes(), contentTopic: contentTopic)

      #  check proofs are added correctly
      check:
        proofAdded1
        proofAdded2
        proofAdded3

      #  relay handler for node3
      var completionFut1 = newFuture[bool]()
      var completionFut2 = newFuture[bool]()
      var completionFut3 = newFuture[bool]()
      var completionFut4 = newFuture[bool]()
      proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        let msg = WakuMessage.init(data)
        if msg.isOk():
          let wm = msg.value()
          debug "The received topic:", topic
          if topic == rlnRelayPubSubTopic:
            if wm == wm1:
              completionFut1.complete(true)
            if wm == wm2:
              completionFut2.complete(true)
            if wm == wm3:
              completionFut3.complete(true)
            if wm == wm4:
              completionFut4.complete(true)
          

      # mount the relay handler for node3
      node3.subscribe(rlnRelayPubSubTopic, relayHandler)
      await sleepAsync(2000.millis)

      ## node1 publishes and relays 4 messages to node2
      ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
      ## node2 relays either of wm1 or wm2 to node3, depending on which message arrives at node2 first
      ## node2 should detect either of wm1 or wm2 as spam and not relay it
      ## node2 should relay wm3 to node3
      ## node2 should not relay wm4 because it has no valid rln proof
      await node1.publish(rlnRelayPubSubTopic, wm1)
      await node1.publish(rlnRelayPubSubTopic, wm2)
      await node1.publish(rlnRelayPubSubTopic, wm3)
      await node1.publish(rlnRelayPubSubTopic, wm4)
      await sleepAsync(2000.millis)

      let 
        res1 = await completionFut1.withTimeout(10.seconds)
        res2 = await completionFut2.withTimeout(10.seconds)

      check:
        res1 or res2 == true # either of the wm1 and wm2 is relayed
        (res1 and res2) == false # either of the wm1 and wm2 is found as spam hence not relayed
        (await completionFut2.withTimeout(10.seconds)) == true
        (await completionFut3.withTimeout(10.seconds)) == true
        (await completionFut4.withTimeout(10.seconds)) == false
      
      await node1.stop()
      await node2.stop()
      await node3.stop()
  asyncTest "Relay protocol is started correctly":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))

    # Relay protocol starts if mounted after node start

    await node1.start()

    node1.mountRelay()

    check:
      GossipSub(node1.wakuRelay).heartbeatFut.isNil == false

    # Relay protocol starts if mounted before node start

    let
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60010))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60012))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
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

    discard await node1.peerManager.dialPeer(node2.switch.peerInfo.toRemotePeerInfo(), WakuLightPushCodec)
    await sleepAsync(5.seconds)
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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

  #   check:
  #     (await completionFutRelay.withTimeout(5.seconds)) == true
  #     (await completionFutLightPush.withTimeout(5.seconds)) == true
  #   await node1.stop()
  #   await node2.stop()
  #   await node3.stop()
  asyncTest "Resume proc fetches the history":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      message = WakuMessage(payload: "hello world".toBytes(), contentTopic: contentTopic)

    await node1.start()
    node1.mountStore(persistMessages = true)
    await node2.start()
    node2.mountStore(persistMessages = true)

    await node2.wakuStore.handleMessage("/waku/2/default-waku/proto", message)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())

    await node1.resume()

    check:
      # message is correctly stored
      node1.wakuStore.messages.len == 1

    await node1.stop()
    await node2.stop()

  asyncTest "Resume proc discards duplicate messages":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      msg1 = WakuMessage(payload: "hello world1".toBytes(), contentTopic: contentTopic, timestamp: 1)
      msg2 = WakuMessage(payload: "hello world2".toBytes(), contentTopic: contentTopic, timestamp: 2)

    # setup sqlite database for node1
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
    

    var completionFut = newFuture[bool]()

    await node1.start()
    node1.mountStore(persistMessages = true, store = store)
    await node2.start()
    node2.mountStore(persistMessages = true)

    await node2.wakuStore.handleMessage(DefaultTopic, msg1)
    await node2.wakuStore.handleMessage(DefaultTopic, msg2)

    await sleepAsync(2000.millis)

    node1.wakuStore.setPeer(node2.switch.peerInfo.toRemotePeerInfo())
    

    # populate db with msg1 to be a duplicate
    let index1 = computeIndex(msg1)
    let output1 = store.put(index1, msg1, DefaultTopic)
    check output1.isOk
    node1.wakuStore.messages.add(IndexedWakuMessage(msg: msg1, index: index1, pubsubTopic: DefaultTopic))
    
    # now run the resume proc
    await node1.resume()

    # count the total number of retrieved messages from the database
    var responseCount = 0
    proc data(receiverTimestamp: float64, msg: WakuMessage, psTopic: string) =
      responseCount += 1
    # retrieve all the messages in the db
    let res = store.getAll(data)
    check:
      res.isErr == false

    check:
      # if the duplicates are discarded properly, then the total number of messages after resume should be 2
      # check no duplicates is in the messages field
      node1.wakuStore.messages.len == 2 
      # check no duplicates is in the db
      responseCount == 2

    await node1.stop()
    await node2.stop()

  asyncTest "Maximum connections can be configured":
    let
      maxConnections = 2
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60010), maxConnections = maxConnections)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60012))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60013))
    
    check:
      # Sanity check, to verify config was applied
      node1.switch.connManager.inSema.size == maxConnections

    # Node with connection limit set to 1
    await node1.start()
    node1.mountRelay() 

    # Remote node 1
    await node2.start()
    node2.mountRelay()

    # Remote node 2
    await node3.start()
    node3.mountRelay()

    discard await node1.peerManager.dialPeer(node2.switch.peerInfo.toRemotePeerInfo(), WakuRelayCodec)
    await sleepAsync(3.seconds)
    discard await node1.peerManager.dialPeer(node3.switch.peerInfo.toRemotePeerInfo(), WakuRelayCodec)

    check:
      # Verify that only the first connection succeeded
      node1.switch.isConnected(node2.switch.peerInfo.peerId)
      node1.switch.isConnected(node3.switch.peerInfo.peerId) == false

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

    
asyncTest "Messages are relayed between two websocket nodes":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60000), wsBindPort = Port(8000), wsEnabled = true)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60002), wsBindPort = Port(8100), wsEnabled = true)
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)
    
    await node2.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()


asyncTest "Messages are relayed between nodes with multiple transports (TCP and Websockets)":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60000), wsBindPort = Port(8000), wsEnabled = true)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60002))
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)
    
    await node2.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

asyncTest "Messages relaying fails with non-overlapping transports (TCP or Websockets)":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60002), wsBindPort = Port(8100), wsEnabled = true)
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    #delete websocket peer address
    # TODO: a better way to find the index - this is too brittle
    node2.switch.peerInfo.addrs.delete(0)

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)
    
    await node2.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == false
    await node1.stop()
    await node2.stop()

asyncTest "Messages are relayed between nodes with multiple transports (TCP and secure Websockets)":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60000), wsBindPort = Port(8000), wssEnabled = true, secureKey = KEY_PATH, secureCert = CERT_PATH)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60002))
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)
    
    await node2.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

asyncTest "Messages fails with wrong key path":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
  
    expect IOError:
      # gibberish
      discard WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60000), wsBindPort = Port(8000), wssEnabled = true, secureKey = "../../waku/v2/node/key_dummy.txt")

asyncTest "Messages are relayed between nodes with multiple transports (websocket and secure Websockets)":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60000), wsBindPort = Port(8000), wssEnabled = true, secureKey = KEY_PATH, secureCert = CERT_PATH)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60002),wsBindPort = Port(8100), wsEnabled = true )
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    node1.mountRelay(@[pubSubTopic])

    await node2.start()
    node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)
    
    await node2.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()
  
asyncTest "Peer info updates with correct announced addresses":
  let
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
    bindIp = ValidIpAddress.init("0.0.0.0")
    bindPort = Port(60000)
    extIp = some(ValidIpAddress.init("127.0.0.1"))
    extPort = some(Port(60002))
    node = WakuNode.new(
      nodeKey,
      bindIp, bindPort,
      extIp, extPort)
     
  let
    bindEndpoint = MultiAddress.init(bindIp, tcpProtocol, bindPort)
    announcedEndpoint = MultiAddress.init(extIp.get(), tcpProtocol, extPort.get())

  check:
    # Check that underlying peer info contains only bindIp before starting
    node.switch.peerInfo.addrs.len == 1
    node.switch.peerInfo.addrs.contains(bindEndpoint)
    
    node.announcedAddresses.len == 1
    node.announcedAddresses.contains(announcedEndpoint)
      
  await node.start()

  check:
    # Check that underlying peer info is updated with announced address
    node.started
    node.switch.peerInfo.addrs.len == 1
    node.switch.peerInfo.addrs.contains(announcedEndpoint)

  await node.stop()
