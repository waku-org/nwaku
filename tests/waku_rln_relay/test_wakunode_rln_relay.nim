{.used.}

import
  std/[sequtils, tempfiles],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub,
  eth/keys
import
  ../../../waku/waku_core,
  ../../../waku/waku_node,
  ../../../waku/waku_rln_relay,
  ../../../waku/waku_keystore,
  ../testlib/wakucore,
  ../testlib/wakunode

from std/times import epochTime

procSuite "WakuNode - RLN relay":
  asyncTest "testing rln-relay with valid proof":

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

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultPubsubTopic])

    # mount rlnrelay in off-chain mode
    await node1.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 1.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode"),
    ))

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultPubsubTopic])
    # mount rlnrelay in off-chain mode
    await node2.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 2.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_2"),
    ))

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultPubsubTopic])

    await node3.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 3.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_3"),
    ))

    await node3.start()

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      debug "The received topic:", topic
      if topic == DefaultPubsubTopic:
        completionFut.complete(true)

    # mount the relay handler
    node3.subscribe(DefaultPubsubTopic, relayHandler)
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "Hello".toBytes()

    # prepare the epoch
    var message = WakuMessage(payload: @payload, contentTopic: contentTopic)
    doAssert(node1.wakuRlnRelay.appendRLNProof(message, epochTime()))


    ## node1 publishes a message with a rate limit proof, the message is then relayed to node2 which in turn
    ## verifies the rate limit proof of the message and relays the message to node3
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    await node1.publish(DefaultPubsubTopic, message)
    await sleepAsync(2000.millis)


    check:
      (await completionFut.withTimeout(10.seconds)) == true

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "testing rln-relay is applied in all rln pubsub/content topics":

    # create 3 nodes
    let nodes = toSeq(0..<3).mapIt(newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0)))
    await allFutures(nodes.mapIt(it.start()))

    let pubsubTopics = @[
        PubsubTopic("/waku/2/pubsubtopic-a/proto"),
        PubsubTopic("/waku/2/pubsubtopic-b/proto")]
    let contentTopics = @[
        ContentTopic("/waku/2/content-topic-a/proto"),
        ContentTopic("/waku/2/content-topic-b/proto")]

    # set up three nodes
    await allFutures(nodes.mapIt(it.mountRelay(pubsubTopics)))

    # mount rlnrelay in off-chain mode
    for index, node in nodes:
      await node.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
        rlnRelayCredIndex: index.uint + 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $(index+1))))

    # start them
    await allFutures(nodes.mapIt(it.start()))

    # connect them together
    await nodes[0].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])
    await nodes[2].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])

    var rxMessagesTopic1 = 0
    var rxMessagesTopic2 = 0
    proc relayHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      info "relayHandler. The received topic:", topic
      if topic == pubsubTopics[0]:
        rxMessagesTopic1 = rxMessagesTopic1 + 1
      elif topic == pubsubTopics[1]:
        rxMessagesTopic2 = rxMessagesTopic2 + 1

    # mount the relay handlers
    nodes[2].subscribe(pubsubTopics[0], relayHandler)
    nodes[2].subscribe(pubsubTopics[1], relayHandler)
    await sleepAsync(1000.millis)

    # publish 5+5 messages to both pubsub topics and content topics
    for i in 0..<5:
      var message1 = WakuMessage(payload: ("Payload_" & $i).toBytes(), contentTopic: contentTopics[0])
      doAssert(nodes[0].wakuRlnRelay.appendRLNProof(message1, epochTime()))

      var message2 = WakuMessage(payload: ("Payload_" & $i).toBytes(), contentTopic: contentTopics[1])
      doAssert(nodes[1].wakuRlnRelay.appendRLNProof(message2, epochTime()))

      await nodes[0].publish(pubsubTopics[0], message1)
      await nodes[1].publish(pubsubTopics[1], message2)

    # wait for gossip to propagate
    await sleepAsync(2000.millis)

    # check that node[2] got messages from both topics
    # and that rln was applied (4+4 messages were spam)
    check:
      rxMessagesTopic1 == 1
      rxMessagesTopic2 == 1

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "testing rln-relay with invalid proof":
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

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultPubsubTopic])

    # mount rlnrelay in off-chain mode
    await node1.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 1.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_4"),
      rlnRelayBandwidthThreshold: 0,
    ))

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultPubsubTopic])
    # mount rlnrelay in off-chain mode
    await node2.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 2.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_5"),
      rlnRelayBandwidthThreshold: 0,
    ))

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultPubsubTopic])

    await node3.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 3.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_6"),
      rlnRelayBandwidthThreshold: 0,
    ))

    await node3.start()

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # define a custom relay handler
    var completionFut = newFuture[bool]()
    proc relayHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      debug "The received topic:", topic
      if topic == DefaultPubsubTopic:
        completionFut.complete(true)

    # mount the relay handler
    node3.subscribe(DefaultPubsubTopic, relayHandler)
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "Hello".toBytes()

    # prepare the epoch
    let epoch = getCurrentEpoch()

    # prepare the proof
    let
      contentTopicBytes = contentTopic.toBytes
      input = concat(payload, contentTopicBytes)
      extraBytes: seq[byte] = @[byte(1),2,3]
      rateLimitProofRes = node1.wakuRlnRelay.groupManager.generateProof(concat(input, extraBytes),   # we add extra bytes to invalidate proof verification against original payload
                                                                        epoch)
    require:
      rateLimitProofRes.isOk()
    let rateLimitProof = rateLimitProofRes.get().encode().buffer

    let message = WakuMessage(payload: @payload,
                              contentTopic: contentTopic,
                              proof: rateLimitProof)


    ## node1 publishes a message with an invalid rln proof, the message is then relayed to node2 which in turn
    ## attempts to verify the rate limit proof and fails hence does not relay the message to node3, thus the relayHandler of node3
    ## never gets called
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    await node1.publish(DefaultPubsubTopic, message)
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
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(0))

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultPubsubTopic])

    # mount rlnrelay in off-chain mode
    await node1.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 1.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_7"),
      rlnRelayBandwidthThreshold: 0,
    ))

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultPubsubTopic])

    # mount rlnrelay in off-chain mode
    await node2.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 2.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_8"),
      rlnRelayBandwidthThreshold: 0,
    ))

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultPubsubTopic])

    # mount rlnrelay in off-chain mode
    await node3.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayCredIndex: 3.uint,
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_9"),
      rlnRelayBandwidthThreshold: 0,
    ))

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
      wm2 = WakuMessage(payload: "message 2".toBytes(), contentTopic: contentTopic)
      proofAdded2 = node3.wakuRlnRelay.appendRLNProof(wm2, time)
      #  wm3 points to the next epoch
      wm3 = WakuMessage(payload: "message 3".toBytes(), contentTopic: contentTopic)
      proofAdded3 = node3.wakuRlnRelay.appendRLNProof(wm3, time+EpochUnitSeconds)
      wm4 = WakuMessage(payload: "message 4".toBytes(), contentTopic: contentTopic)

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
    proc relayHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      debug "The received topic:", topic
      if topic == DefaultPubsubTopic:
        if msg == wm1:
          completionFut1.complete(true)
        if msg == wm2:
          completionFut2.complete(true)
        if msg == wm3:
          completionFut3.complete(true)
        if msg == wm4:
          completionFut4.complete(true)


    # mount the relay handler for node3
    node3.subscribe(DefaultPubsubTopic, relayHandler)
    await sleepAsync(2000.millis)

    ## node1 publishes and relays 4 messages to node2
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    ## node2 relays either of wm1 or wm2 to node3, depending on which message arrives at node2 first
    ## node2 should detect either of wm1 or wm2 as spam and not relay it
    ## node2 should relay wm3 to node3
    ## node2 should not relay wm4 because it has no valid rln proof
    await node1.publish(DefaultPubsubTopic, wm1)
    await node1.publish(DefaultPubsubTopic, wm2)
    await node1.publish(DefaultPubsubTopic, wm3)
    await node1.publish(DefaultPubsubTopic, wm4)
    await sleepAsync(2000.millis)

    let
      res1 = await completionFut1.withTimeout(10.seconds)
      res2 = await completionFut2.withTimeout(10.seconds)

    check:
      (res1 and res2) == false # either of the wm1 and wm2 is found as spam hence not relayed
      (await completionFut3.withTimeout(10.seconds)) == true
      (await completionFut4.withTimeout(10.seconds)) == false

    await node1.stop()
    await node2.stop()
    await node3.stop()
