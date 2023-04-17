{.used.}

import
  std/[os, sequtils, sysrand, math],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/multihash,
  secp256k1
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/waku_node,
  ../../waku/v2/protocol/waku_relay,
  ../../waku/v2/protocol/waku_relay/validators,
  ../testlib/testutils,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode

template sourceDir: string = currentSourcePath.parentDir()
const KEY_PATH = sourceDir / "resources/test_key.pem"
const CERT_PATH = sourceDir / "resources/test_cert.pem"

suite "WakuNode - Relay":

  asyncTest "Relay protocol is started correctly":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0))

    # Relay protocol starts if mounted after node start

    await node1.start()
    await node1.mountRelay()

    check:
      GossipSub(node1.wakuRelay).heartbeatFut.isNil() == false

    # Relay protocol starts if mounted before node start

    let
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))

    await node2.mountRelay()

    check:
      # Relay has not yet started as node has not yet started
      GossipSub(node2.wakuRelay).heartbeatFut.isNil()

    await node2.start()

    check:
      # Relay started on node start
      GossipSub(node2.wakuRelay).heartbeatFut.isNil() == false

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Messages are correctly relayed":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(0))
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[pubSubTopic])

    await allFutures(
      node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()]),
      node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    )

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node3.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(500.millis)

    await node1.publish(pubSubTopic, message)

    ## Then
    check:
      (await completionFut.withTimeout(5.seconds)) == true

    ## Cleanup
    await allFutures(node1.stop(), node2.stop(), node3.stop())

  asyncTest "filtering relayed messages using topic validators":
    ## test scenario:
    ## node1 and node3 set node2 as their relay node
    ## node3 publishes two messages with two different contentTopics but on the same pubsub topic
    ## node1 is also subscribed  to the same pubsub topic
    ## node2 sets a validator for the same pubsub topic
    ## only one of the messages gets delivered to  node1 because the validator only validates one of the content topics

    let
      # publisher node
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(0))

      pubSubTopic = "test"
      contentTopic1 = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message1 = WakuMessage(payload: payload, contentTopic: contentTopic1)

      payload2 = "you should not see this message!".toBytes()
      contentTopic2 = ContentTopic("2")
      message2 = WakuMessage(payload: payload2, contentTopic: contentTopic2)

    # start all the nodes
    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node3.start()
    await node3.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFutValidatorAcc = newFuture[bool]()
    var completionFutValidatorRej = newFuture[bool]()

    # set a topic validator for pubSubTopic
    proc validator(topic: string, message: messages.Message): Future[ValidationResult] {.async.} =
      ## the validator that only allows messages with contentTopic1 to be relayed
      check:
        topic == pubSubTopic

      let msg = WakuMessage.decode(message.data)
      if msg.isErr():
        completionFutValidatorAcc.complete(false)
        return ValidationResult.Reject

      # only relay messages with contentTopic1
      if msg.value.contentTopic  != contentTopic1:
        completionFutValidatorRej.complete(true)
        return ValidationResult.Reject

      completionFutValidatorAcc.complete(true)
      return ValidationResult.Accept

    node2.wakuRelay.addValidator(pubSubTopic, validator)

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      debug "relayed pubsub topic:", topic
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          # check that only messages with contentTopic1 is relayed (but not contentTopic2)
          val.contentTopic == contentTopic1
      # relay handler is called
      completionFut.complete(true)


    node3.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(500.millis)

    await node1.publish(pubSubTopic, message1)
    await sleepAsync(500.millis)

    # message2 never gets relayed because of the validator
    await node1.publish(pubSubTopic, message2)
    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(10.seconds)) == true
      # check that validator is called for message1
      (await completionFutValidatorAcc.withTimeout(10.seconds)) == true
      # check that validator is called for message2
      (await completionFutValidatorRej.withTimeout(10.seconds)) == true

    await allFutures(node1.stop(), node2.stop(), node3.stop())

  # TODO: Add a function to validate the WakuMessage integrity
  xasyncTest "Stats of peer sending wrong WakuMessages are updated":
    # Create 2 nodes
    let nodes = toSeq(0..1).mapIt(newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    # Start all the nodes and mount relay with
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Connect nodes
    let connOk = await nodes[0].peerManager.connectRelay(nodes[1].switch.peerInfo.toRemotePeerInfo())
    require:
      connOk == true

    # Node 1 subscribes to topic
    nodes[1].subscribe(DefaultPubsubTopic)
    await sleepAsync(500.millis)

    # Node 0 publishes 5 messages not compliant with WakuMessage (aka random bytes)
    for i in 0..4:
      discard await nodes[0].wakuRelay.publish(DefaultPubsubTopic, urandom(1*(10^2)))

    # Wait for gossip
    await sleepAsync(500.millis)

    # Verify that node 1 has received 5 invalid messages from node 0
    # meaning that message validity is enforced to gossip messages
    var peerStats = nodes[1].wakuRelay.peerStats
    check:
      peerStats[nodes[0].switch.peerInfo.peerId].topicInfos[DefaultPubsubTopic].invalidMessageDeliveries == 5.0

    await allFutures(nodes.mapIt(it.stop()))

  # TODO: Test multiple protected topics

  asyncTest "Spam protected topic accepts signed messages":
    # Create 5 nodes
    let nodes = toSeq(0..<5).mapIt(newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    # Protected topic and key to sign
    let spamProtectedTopic = PubSubTopic("some-spam-protected-topic")
    let secretKey = SkSecretKey.fromHex("5526a8990317c9b7b58d07843d270f9cd1d9aaee129294c1c478abf7261dd9e6").expect("valid key")
    let publicKey = secretKey.toPublicKey()
    let topicsPrivateKeys = {spamProtectedTopic: secretKey}.toTable
    let topicsPublicKeys = {spamProtectedTopic: publicKey}.toTable

    # Start all the nodes and mount relay with protected topic
    await allFutures(nodes.mapIt(it.start()))

    # Mount relay for all nodes
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Add signed message validator to all nodes. They will only route signed messages
    for node in nodes:
      for topic, publicKey in topicsPublicKeys:
        node.wakuRelay.addSignedTopicValidator(PubsubTopic(topic), publicKey)

    # Connect the nodes in a full mesh
    for i in 0..<5:
      for j in 0..<5:
        if i == j:
          continue
        let connOk = await nodes[i].peerManager.connectRelay(nodes[j].switch.peerInfo.toRemotePeerInfo())
        require connOk

    var msgReceived = 0
    proc handler(pubsubTopic: PubsubTopic, data: WakuMessage) {.async, gcsafe.} =
      msgReceived += 1

    # Subscribe all nodes to the same topic/handler
    for node in nodes: node.wakuRelay.subscribe(spamProtectedTopic, handler)
    await sleepAsync(500.millis)

    # Each node publishes 10 signed messages
    for i in 0..<5:
      for j in 0..<10:
        var msg = WakuMessage(
          payload: urandom(1*(10^3)), contentTopic: spamProtectedTopic,
          version: 2, timestamp: now(), ephemeral: true)

        # Include signature
        msg.meta = secretKey.sign(SkMessage(spamProtectedTopic.msgHash(msg))).toRaw()[0..63]

        await nodes[i].publish(spamProtectedTopic, msg)

    # Wait for gossip
    await sleepAsync(1.seconds)

    # 50 messages were sent to 5 peers = 250 messages
    check:
      msgReceived == 250

    # No invalid messages were received by any peer
    for i in 0..<5:
      for k, v in nodes[i].wakuRelay.peerStats.mpairs:
        check:
          v.topicInfos[spamProtectedTopic].invalidMessageDeliveries == 0.0

    # Stop all nodes
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Spam protected topic rejects non-signed and wrongly-signed messages":
    # Create 5 nodes
    let nodes = toSeq(0..<5).mapIt(newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    # Protected topic and key to sign
    let spamProtectedTopic = PubSubTopic("some-spam-protected-topic")
    let secretKey = SkSecretKey.fromHex("5526a8990317c9b7b58d07843d270f9cd1d9aaee129294c1c478abf7261dd9e6").expect("valid key")
    let publicKey = secretKey.toPublicKey()
    let topicsPrivateKeys = {spamProtectedTopic: secretKey}.toTable
    let topicsPublicKeys = {spamProtectedTopic: publicKey}.toTable

    # Non whitelisted secret key
    let wrongSecretKey = SkSecretKey.fromHex("32ad0cc8edeb9f8a3e8635c5fe5bd200b9247a33da5e7171bd012691805151f3").expect("valid key")

    # Start all the nodes and mount relay with protected topic
    await allFutures(nodes.mapIt(it.start()))

    # Mount relay with spam protected topics
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Add signed message validator to all nodes. They will only route signed messages
    for node in nodes:
      for topic, publicKey in topicsPublicKeys:
        node.wakuRelay.addSignedTopicValidator(PubsubTopic(topic), publicKey)

    # Connect the nodes in a full mesh
    for i in 0..<5:
      for j in 0..<5:
        if i == j:
          continue
        let connOk = await nodes[i].peerManager.connectRelay(nodes[j].switch.peerInfo.toRemotePeerInfo())
        require connOk

    var msgReceived = 0
    proc handler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      msgReceived += 1

    # Subscribe all nodes to the same topic/handler
    for node in nodes: node.wakuRelay.subscribe(spamProtectedTopic, handler)
    await sleepAsync(500.millis)

    # Each node sends 10 messages, signed but with a non-whitelisted key (total = 50)
    for i in 0..<5:
      for j in 0..<10:
        var msg = WakuMessage(
          payload: urandom(1*(10^3)), contentTopic: spamProtectedTopic,
          version: 2, timestamp: now(), ephemeral: true)

        # Sign the message with a wrong key
        msg.meta = wrongSecretKey.sign(SkMessage(spamProtectedTopic.msgHash(msg))).toRaw()[0..63]

        await nodes[i].publish(spamProtectedTopic, msg)

    # Each node sends 10 messages that are not signed (total = 50)
    for i in 0..<5:
      for j in 0..<10:
        let unsignedMessage = WakuMessage(
          payload: urandom(1*(10^3)), contentTopic: spamProtectedTopic,
          version: 2, timestamp: now(), ephemeral: true)
        await nodes[i].publish(spamProtectedTopic, unsignedMessage)

    # Wait for gossip
    await sleepAsync(1.seconds)

    # Since we have a full mesh with 5 nodes and each one publishes 50+50 msgs
    # there are 500 messages being sent.
    # 100 are received ok in the handler (first hop)
    # 400 are are wrong so rejected (rejected not relayed)
    check:
      msgReceived == 100

    var msgRejected = 0
    for i in 0..<5:
      for k, v in nodes[i].wakuRelay.peerStats.mpairs:
        msgRejected += v.topicInfos[spamProtectedTopic].invalidMessageDeliveries.int

    check:
      msgRejected == 400

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Spam protected topic rejects a spammer node":
    # Create 5 nodes
    let nodes = toSeq(0..<5).mapIt(newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    # Protected topic and key to sign
    let spamProtectedTopic = PubSubTopic("some-spam-protected-topic")
    let secretKey = SkSecretKey.fromHex("5526a8990317c9b7b58d07843d270f9cd1d9aaee129294c1c478abf7261dd9e6").expect("valid key")
    let publicKey = secretKey.toPublicKey()
    let topicsPrivateKeys = {spamProtectedTopic: secretKey}.toTable
    let topicsPublicKeys = {spamProtectedTopic: publicKey}.toTable

    # Non whitelisted secret key
    let wrongSecretKey = SkSecretKey.fromHex("32ad0cc8edeb9f8a3e8635c5fe5bd200b9247a33da5e7171bd012691805151f3").expect("valid key")

    # Start all the nodes and mount relay with protected topic
    await allFutures(nodes.mapIt(it.start()))

    # Mount relay for all nodes
    await allFutures(nodes.mapIt(it.mountRelay()))

    var msgReceived = 0
    proc handler(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      msgReceived += 1

    # Subscribe all nodes to the same topic/handler
    for node in nodes: node.wakuRelay.subscribe(spamProtectedTopic, handler)
    await sleepAsync(500.millis)

    # Add signed message validator to all nodes. They will only route signed messages
    for node in nodes:
      for topic, publicKey in topicsPublicKeys:
        node.wakuRelay.addSignedTopicValidator(PubsubTopic(topic), publicKey)

    # nodes[0] is connected only to nodes[1]
    let connOk1 = await nodes[0].peerManager.connectRelay(nodes[1].switch.peerInfo.toRemotePeerInfo())
    require connOk1

    # rest of nodes[1..4] are connected in a full mesh
    for i in 1..<5:
      for j in 1..<5:
        if i == j:
          continue
        let connOk2 = await nodes[i].peerManager.connectRelay(nodes[j].switch.peerInfo.toRemotePeerInfo())
        require connOk2

    await sleepAsync(500.millis)

    # nodes[0] spams 50 non signed messages (nodes[0] just knows of nodes[1])
    for j in 0..<50:
      let unsignedMessage = WakuMessage(
        payload: urandom(1*(10^3)), contentTopic: spamProtectedTopic,
        version: 2, timestamp: now(), ephemeral: true)
      await nodes[0].publish(spamProtectedTopic, unsignedMessage)

    # nodes[0] spams 50 wrongly signed messages (nodes[0] just knows of nodes[1])
    for j in 0..<50:
      var msg = WakuMessage(
        payload: urandom(1*(10^3)), contentTopic: spamProtectedTopic,
        version: 2, timestamp: now(), ephemeral: true)
      # Sign the message with a wrong key
      msg.meta = wrongSecretKey.sign(SkMessage(spamProtectedTopic.msgHash(msg))).toRaw()[0..63]
      await nodes[0].publish(spamProtectedTopic, msg)

    # Wait for gossip
    await sleepAsync(1.seconds)

    # only 100 messages are received (50 + 50) which demonstrate
    # nodes[1] doest gossip invalid messages.
    check:
      msgReceived == 100

    # peer1 got invalid messages from peer0
    let p0Id = nodes[0].peerInfo.peerId
    check:
      nodes[1].wakuRelay.peerStats[p0Id].topicInfos[spamProtectedTopic].invalidMessageDeliveries == 100.0

    # peer1 did not gossip further, so no other node rx invalid messages
    for i in 0..<5:
      for k, v in nodes[i].wakuRelay.peerStats.mpairs:
        if k == p0Id and i == 1:
          continue
        check:
          v.topicInfos[spamProtectedTopic].invalidMessageDeliveries == 0.0

    # Stop all nodes
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Messages are relayed between two websocket nodes":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60510), wsBindPort = Port(8001), wsEnabled = true)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60512), wsBindPort = Port(8101), wsEnabled = true)
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(500.millis)

    await node2.publish(pubSubTopic, message)
    await sleepAsync(500.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Messages are relayed between nodes with multiple transports (TCP and Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60520), wsBindPort = Port(8002), wsEnabled = true)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60522))
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(500.millis)

    await node2.publish(pubSubTopic, message)
    await sleepAsync(500.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Messages relaying fails with non-overlapping transports (TCP or Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60530))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60532), wsBindPort = Port(8103), wsEnabled = true)
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    #delete websocket peer address
    # TODO: a better way to find the index - this is too brittle
    node2.switch.peerInfo.listenAddrs.delete(0)

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(500.millis)

    await node2.publish(pubSubTopic, message)
    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == false

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Messages are relayed between nodes with multiple transports (TCP and secure Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60540), wsBindPort = Port(8004), wssEnabled = true, secureKey = KEY_PATH, secureCert = CERT_PATH)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(60542))
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(500.millis)

    await node2.publish(pubSubTopic, message)
    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Messages are relayed between nodes with multiple transports (websocket and secure Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), bindPort = Port(60550), wsBindPort = Port(8005), wssEnabled = true, secureKey = KEY_PATH, secureCert = CERT_PATH)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), bindPort = Port(60552),wsBindPort = Port(8105), wsEnabled = true )

    let
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node1.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(500.millis)

    await node2.publish(pubSubTopic, message)
    await sleepAsync(500.millis)


    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()
