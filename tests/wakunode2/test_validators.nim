{.used.}

import
  std/[sequtils, sysrand, math],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/multihash,
  secp256k1
import
  ../../apps/wakunode2/wakunode2_validator_signed,
  ../../waku/v2/waku_core,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/waku_node,
  ../../waku/v2/waku_relay,
  ../v2/testlib/wakucore,
  ../v2/testlib/wakunode

suite "WakuNode2 - Validators":

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

    # Connection triggers different actions, wait for them
    await sleepAsync(500.millis)

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
    await sleepAsync(2.seconds)

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

    # Connection triggers different actions, wait for them
    await sleepAsync(500.millis)

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
    await sleepAsync(2.seconds)

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

    # Connection triggers different actions, wait for them
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
    await sleepAsync(2.seconds)

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
