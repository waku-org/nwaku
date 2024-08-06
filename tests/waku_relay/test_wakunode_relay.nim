{.used.}

import
  std/[os, sequtils, sysrand, math],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub
import
  waku/[waku_core, node/peer_manager, waku_node, waku_relay],
  ../testlib/testutils,
  ../testlib/wakucore,
  ../testlib/wakunode

template sourceDir(): string =
  currentSourcePath.parentDir()

const KEY_PATH = sourceDir / "resources/test_key.pem"
const CERT_PATH = sourceDir / "resources/test_cert.pem"

suite "WakuNode - Relay":
  asyncTest "Relay protocol is started correctly":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))

    # Relay protocol starts if mounted after node start

    await node1.start()
    await node1.mountRelay()

    check:
      GossipSub(node1.wakuRelay).heartbeatFut.isNil() == false

    # Relay protocol starts if mounted before node start

    let
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))

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
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))
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
      node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()]),
    )

    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    node3.subscribe(
      (kind: topics.Subscribe, pubsubTopic: pubsubTopic, contentTopics: @[""]),
      some(relayHandler),
    )
    await sleepAsync(500.millis)

    var res = await node1.publish(some(pubSubTopic), message)
    assert res.isOk(), $res.error

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
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))

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
    proc validator(
        topic: string, msg: WakuMessage
    ): Future[ValidationResult] {.async.} =
      ## the validator that only allows messages with contentTopic1 to be relayed
      check:
        topic == pubSubTopic

      # only relay messages with contentTopic1
      if msg.contentTopic != contentTopic1:
        completionFutValidatorRej.complete(true)
        return ValidationResult.Reject

      completionFutValidatorAcc.complete(true)
      return ValidationResult.Accept

    node2.wakuRelay.addValidator(validator)

    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        # check that only messages with contentTopic1 is relayed (but not contentTopic2)
        msg.contentTopic == contentTopic1
      # relay handler is called
      completionFut.complete(true)

    node3.subscribe(
      (kind: topics.Subscribe, pubsubTopic: pubsubTopic, contentTopics: @[""]),
      some(relayHandler),
    )
    await sleepAsync(500.millis)

    var res = await node1.publish(some(pubSubTopic), message1)
    assert res.isOk(), $res.error

    await sleepAsync(500.millis)

    # message2 never gets relayed because of the validator
    res = await node1.publish(some(pubSubTopic), message2)
    assert res.isOk(), $res.error

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
    let nodes = toSeq(0 .. 1).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )

    # Start all the nodes and mount relay with
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Connect nodes
    let connOk = await nodes[0].peerManager.connectRelay(
      nodes[1].switch.peerInfo.toRemotePeerInfo()
    )
    require:
      connOk == true

    # Node 1 subscribes to topic
    nodes[1].subscribe(
      (kind: topics.Subscribe, pubsubTopic: DefaultPubsubTopic, contentTopics: @[""])
    )
    await sleepAsync(500.millis)

    # Node 0 publishes 5 messages not compliant with WakuMessage (aka random bytes)
    for i in 0 .. 4:
      discard
        await nodes[0].wakuRelay.publish(DefaultPubsubTopic, urandom(1 * (10 ^ 2)))

    # Wait for gossip
    await sleepAsync(500.millis)

    # Verify that node 1 has received 5 invalid messages from node 0
    # meaning that message validity is enforced to gossip messages
    var peerStats = nodes[1].wakuRelay.peerStats
    check:
      peerStats[nodes[0].switch.peerInfo.peerId].topicInfos[DefaultPubsubTopic].invalidMessageDeliveries ==
        5.0

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Messages are relayed between two websocket nodes":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        wsBindPort = Port(0),
        wsEnabled = true,
      )
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(
        nodeKey2,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        wsBindPort = Port(0),
        wsEnabled = true,
      )
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
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    node1.subscribe(
      (kind: topics.Subscribe, pubsubTopic: pubsubTopic, contentTopics: @[""]),
      some(relayHandler),
    )
    await sleepAsync(500.millis)

    let res = await node2.publish(some(pubSubTopic), message)
    assert res.isOk(), $res.error

    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Messages are relayed between nodes with multiple transports (TCP and Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        wsBindPort = Port(0),
        wsEnabled = true,
      )
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), bindPort = Port(0))
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
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    node1.subscribe(
      (kind: topics.Subscribe, pubsubTopic: pubsubTopic, contentTopics: @[""]),
      some(relayHandler),
    )
    await sleepAsync(500.millis)

    let res = await node2.publish(some(pubSubTopic), message)
    assert res.isOk(), $res.error

    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Messages relaying fails with non-overlapping transports (TCP or Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), bindPort = Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(
        nodeKey2,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        wsBindPort = Port(0),
        wsEnabled = true,
      )
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
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    node1.subscribe(
      (kind: topics.Subscribe, pubsubTopic: pubsubTopic, contentTopics: @[""]),
      some(relayHandler),
    )
    await sleepAsync(500.millis)

    let res = await node2.publish(some(pubSubTopic), message)
    assert res.isOk(), $res.error

    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == false

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Messages are relayed between nodes with multiple transports (TCP and secure Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        wsBindPort = Port(0),
        wssEnabled = true,
        secureKey = KEY_PATH,
        secureCert = CERT_PATH,
      )
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), bindPort = Port(0))
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
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    node1.subscribe(
      (kind: topics.Subscribe, pubsubTopic: pubsubTopic, contentTopics: @[""]),
      some(relayHandler),
    )
    await sleepAsync(500.millis)

    let res = await node2.publish(some(pubSubTopic), message)
    assert res.isOk(), $res.error

    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Messages are relayed between nodes with multiple transports (websocket and secure Websockets)":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        wsBindPort = Port(0),
        wssEnabled = true,
        secureKey = KEY_PATH,
        secureCert = CERT_PATH,
      )
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(
        nodeKey2,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        wsBindPort = Port(0),
        wsEnabled = true,
      )

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
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    node1.subscribe(
      (kind: topics.Subscribe, pubsubTopic: pubsubTopic, contentTopics: @[""]),
      some(relayHandler),
    )
    await sleepAsync(500.millis)

    let res = await node2.publish(some(pubSubTopic), message)
    assert res.isOk(), $res.error

    await sleepAsync(500.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
    await node1.stop()
    await node2.stop()

  asyncTest "Bad peers with low reputation are disconnected":
    # Create 5 nodes
    let nodes = toSeq(0 ..< 5).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # subscribe all nodes to a topic
    let topic = "topic"
    for node in nodes:
      discard node.wakuRelay.subscribe(topic, nil)
    await sleepAsync(500.millis)

    # connect nodes in full mesh
    for i in 0 ..< 5:
      for j in 0 ..< 5:
        if i == j:
          continue
        let connOk = await nodes[i].peerManager.connectRelay(
          nodes[j].switch.peerInfo.toRemotePeerInfo()
        )
        require connOk

    # connection triggers different actions, wait for them
    await sleepAsync(1.seconds)

    # all peers are connected in a mesh, 4 conns each
    for i in 0 ..< 5:
      check:
        nodes[i].peerManager.switch.connManager.getConnections().len == 4

    # node[0] publishes wrong messages (random bytes not decoding into WakuMessage)
    for j in 0 ..< 50:
      discard await nodes[0].wakuRelay.publish(topic, urandom(1 * (10 ^ 3)))

    # long wait, must be higher than the configured decayInterval (how often score is updated)
    await sleepAsync(20.seconds)

    # all nodes lower the score of nodes[0] (will change if gossipsub params or amount of msg changes)
    for i in 1 ..< 5:
      check:
        nodes[i].wakuRelay.peerStats[nodes[0].switch.peerInfo.peerId].score == -249999.9

    # nodes[0] was blacklisted from all other peers, no connections
    check:
      nodes[0].peerManager.switch.connManager.getConnections().len == 0

    # the rest of the nodes now have 1 conn less (kicked nodes[0] out)
    for i in 1 ..< 5:
      check:
        nodes[i].peerManager.switch.connManager.getConnections().len == 3

    # Stop all nodes
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Unsubscribe keep the subscription if other content topics also use the shard":
    ## Setup
    let
      nodeKey = generateSecp256k1Key()
      node = newTestWakuNode(nodeKey, parseIpAddress("0.0.0.0"), Port(0))

    await node.start()
    await node.mountRelay()
    require node.mountSharding(1, 1).isOk

    ## Given
    let
      shard = "/waku/2/rs/1/0"
      contentTopicA = DefaultContentTopic
      contentTopicB = ContentTopic("/waku/2/default-content1/proto")
      contentTopicC = ContentTopic("/waku/2/default-content2/proto")
      handler: WakuRelayHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[void] {.gcsafe, raises: [Defect].} =
        discard pubsubTopic
        discard message
    assert shard == node.wakuSharding.getShard(contentTopicA).expect("Valid Topic"),
      "topic must use the same shard"
    assert shard == node.wakuSharding.getShard(contentTopicB).expect("Valid Topic"),
      "topic must use the same shard"
    assert shard == node.wakuSharding.getShard(contentTopicC).expect("Valid Topic"),
      "topic must use the same shard"

    ## When
    node.subscribe(
      (
        kind: Subscribe,
        pubsubTopic: "",
        contentTopics: @[contentTopicA, contentTopicB, contentTopicC],
      ),
      some(handler),
    )

    ## Then
    node.unsubscribe(
      (kind: topics.Unsubscribe, pubsubTopic: "", contentTopics: @[contentTopicB])
    )
    check node.wakuRelay.isSubscribed(shard)

    node.unsubscribe(
      (kind: topics.Unsubscribe, pubsubTopic: "", contentTopics: @[contentTopicA])
    )
    check node.wakuRelay.isSubscribed(shard)

    node.unsubscribe(
      (kind: topics.Unsubscribe, pubsubTopic: "", contentTopics: @[contentTopicC])
    )
    check not node.wakuRelay.isSubscribed(shard)

    ## Cleanup
    await node.stop()
