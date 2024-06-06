{.used.}

import
  std/[sequtils, tempfiles],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub
import
  ../../../waku/waku_core,
  ../../../waku/waku_node,
  ../../../waku/waku_rln_relay,
  ../testlib/wakucore,
  ../testlib/wakunode,
  ./rln/waku_rln_relay_utils

from std/times import epochTime

procSuite "WakuNode - RLN relay":
  # NOTE: we set the rlnRelayUserMessageLimit to 1 to make the tests easier to reason about
  asyncTest "testing rln-relay with valid proof":
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

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultNsPubsubTopic])

    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode"),
      )
    else:
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode"),
      )
    await node1.mountRlnRelay(wakuRlnConfig1)

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultNsPubsubTopic])
    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_2"),
      )
    else:
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_2"),
      )
    await node2.mountRlnRelay(wakuRlnConfig2)

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultNsPubsubTopic])

    when defined(rln_v2):
      let wakuRlnConfig3 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(3.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_3"),
      )
    else:
      let wakuRlnConfig3 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(3.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_3"),
      )
    await node3.mountRlnRelay(wakuRlnConfig3)

    await node3.start()

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      debug "The received topic:", topic
      if topic == DefaultPubsubTopic:
        completionFut.complete(true)

    # mount the relay handler
    node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), some(relayHandler))
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "Hello".toBytes()

    # prepare the epoch
    var message = WakuMessage(payload: @payload, contentTopic: contentTopic)
    doAssert(node1.wakuRlnRelay.unsafeAppendRLNProof(message, epochTime()).isOk())

    ## node1 publishes a message with a rate limit proof, the message is then relayed to node2 which in turn
    ## verifies the rate limit proof of the message and relays the message to node3
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    discard await node1.publish(some(DefaultPubsubTopic), message)
    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(10.seconds)) == true

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "testing rln-relay is applied in all rln pubsub/content topics":
    # create 3 nodes
    let nodes = toSeq(0 ..< 3).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )
    await allFutures(nodes.mapIt(it.start()))

    let pubsubTopics =
      @[
        NsPubsubTopic(clusterId: DefaultClusterId, shardId: 0),
        NsPubsubTopic(clusterId: DefaultClusterId, shardId: 1),
      ]
    let contentTopics =
      @[
        ContentTopic("/waku/2/content-topic-a/proto"),
        ContentTopic("/waku/2/content-topic-b/proto"),
      ]

    # set up three nodes
    await allFutures(nodes.mapIt(it.mountRelay(pubsubTopics)))

    # mount rlnrelay in off-chain mode
    for index, node in nodes:
      when defined(rln_v2):
        let wakuRlnConfig = WakuRlnConfig(
          rlnRelayDynamic: false,
          rlnRelayCredIndex: some(index.uint + 1),
          rlnRelayUserMessageLimit: 1,
          rlnEpochSizeSec: 1,
          rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $(index + 1)),
        )
      else:
        let wakuRlnConfig = WakuRlnConfig(
          rlnRelayDynamic: false,
          rlnRelayCredIndex: some(index.uint + 1),
          rlnEpochSizeSec: 1,
          rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $(index + 1)),
        )
      await node.mountRlnRelay(wakuRlnConfig)

    # start them
    await allFutures(nodes.mapIt(it.start()))

    # connect them together
    await nodes[0].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])
    await nodes[2].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])

    var rxMessagesTopic1 = 0
    var rxMessagesTopic2 = 0
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      info "relayHandler. The received topic:", topic
      if topic == pubsubTopics[0]:
        rxMessagesTopic1 = rxMessagesTopic1 + 1
      elif topic == pubsubTopics[1]:
        rxMessagesTopic2 = rxMessagesTopic2 + 1

    # mount the relay handlers
    nodes[2].subscribe((kind: PubsubSub, topic: $pubsubTopics[0]), some(relayHandler))
    nodes[2].subscribe((kind: PubsubSub, topic: $pubsubTopics[1]), some(relayHandler))
    await sleepAsync(1000.millis)

    # generate some messages with rln proofs first. generating
    # the proof takes some time, so this is done before publishing
    # to avoid blocking the test
    var messages1: seq[WakuMessage] = @[]
    var messages2: seq[WakuMessage] = @[]

    let epochTime = epochTime()

    for i in 0 ..< 3:
      var message = WakuMessage(
        payload: ("Payload_" & $i).toBytes(), contentTopic: contentTopics[0]
      )
      nodes[0].wakuRlnRelay.unsafeAppendRLNProof(message, epochTime).isOkOr:
        raiseAssert $error
      messages1.add(message)

    for i in 0 ..< 3:
      var message = WakuMessage(
        payload: ("Payload_" & $i).toBytes(), contentTopic: contentTopics[1]
      )
      nodes[1].wakuRlnRelay.unsafeAppendRLNProof(message, epochTime).isOkOr:
        raiseAssert $error
      messages2.add(message)

    # publish 3 messages from node[0] (last 2 are spam, window is 10 secs)
    # publish 3 messages from node[1] (last 2 are spam, window is 10 secs)
    for msg in messages1:
      discard await nodes[0].publish(some($pubsubTopics[0]), msg)
    for msg in messages2:
      discard await nodes[1].publish(some($pubsubTopics[1]), msg)

    # wait for gossip to propagate
    await sleepAsync(5000.millis)

    # check that node[2] got messages from both topics
    # and that rln was applied (just 1 msg is rx, rest are spam)
    check:
      rxMessagesTopic1 == 1
      rxMessagesTopic2 == 1

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "testing rln-relay with invalid proof":
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

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultNsPubsubTopic])

    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_4"),
      )
    else:
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_4"),
      )
    await node1.mountRlnRelay(wakuRlnConfig1)

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultNsPubsubTopic])
    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_5"),
      )
    else:
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_5"),
      )
    await node2.mountRlnRelay(wakuRlnConfig2)

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultNsPubsubTopic])

    when defined(rln_v2):
      let wakuRlnConfig3 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(3.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_6"),
      )
    else:
      let wakuRlnConfig3 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(3.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_6"),
      )
    await node3.mountRlnRelay(wakuRlnConfig3)
    await node3.start()

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # define a custom relay handler
    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      debug "The received topic:", topic
      if topic == DefaultPubsubTopic:
        completionFut.complete(true)

    # mount the relay handler
    node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), some(relayHandler))
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "Hello".toBytes()

    # prepare the epoch
    let epoch = node1.wakuRlnRelay.getCurrentEpoch()

    # prepare the proof
    let
      contentTopicBytes = contentTopic.toBytes
      input = concat(payload, contentTopicBytes)
      extraBytes: seq[byte] = @[byte(1), 2, 3]

    when defined(rln_v2):
      let nonceManager = node1.wakuRlnRelay.nonceManager
      let rateLimitProofRes = node1.wakuRlnRelay.groupManager.generateProof(
        concat(input, extraBytes), epoch, MessageId(0)
      )
    else:
      let rateLimitProofRes = node1.wakuRlnRelay.groupManager.generateProof(
        concat(input, extraBytes),
          # we add extra bytes to invalidate proof verification against original payload
        epoch,
      )
    assert rateLimitProofRes.isOk(), $rateLimitProofRes.error
      # check the proof is generated correctly outside when block to avoid duplication
    let rateLimitProof = rateLimitProofRes.get().encode().buffer

    let message =
      WakuMessage(payload: @payload, contentTopic: contentTopic, proof: rateLimitProof)

    ## node1 publishes a message with an invalid rln proof, the message is then relayed to node2 which in turn
    ## attempts to verify the rate limit proof and fails hence does not relay the message to node3, thus the relayHandler of node3
    ## never gets called
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    discard await node1.publish(some(DefaultPubsubTopic), message)
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
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultNsPubsubTopic])

    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_7"),
      )
    else:
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_7"),
      )
    await node1.mountRlnRelay(wakuRlnConfig1)

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultNsPubsubTopic])

    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_8"),
      )
    else:
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_8"),
      )
    await node2.mountRlnRelay(wakuRlnConfig2)
    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultNsPubsubTopic])

    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig3 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(3.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_9"),
      )
    else:
      let wakuRlnConfig3 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(3.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_9"),
      )
    await node3.mountRlnRelay(wakuRlnConfig3)

    await node3.start()

    # connect the nodes together node1 <-> node2 <-> node3
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # get the current epoch time
    let time = epochTime()
    #  create some messages with rate limit proofs
    var
      wm1 = WakuMessage(payload: "message 1".toBytes(), contentTopic: contentTopic)
      # another message in the same epoch as wm1, it will break the messaging rate limit
      wm2 = WakuMessage(payload: "message 2".toBytes(), contentTopic: contentTopic)
      #  wm3 points to the next epoch
      wm3 = WakuMessage(payload: "message 3".toBytes(), contentTopic: contentTopic)
      wm4 = WakuMessage(payload: "message 4".toBytes(), contentTopic: contentTopic)

    node3.wakuRlnRelay.unsafeAppendRLNProof(wm1, time).isOkOr:
      raiseAssert $error
    node3.wakuRlnRelay.unsafeAppendRLNProof(wm2, time).isOkOr:
      raiseAssert $error

    node3.wakuRlnRelay.unsafeAppendRLNProof(
      wm3, time + float64(node3.wakuRlnRelay.rlnEpochSizeSec)
    ).isOkOr:
      raiseAssert $error

    #  relay handler for node3
    var completionFut1 = newFuture[bool]()
    var completionFut2 = newFuture[bool]()
    var completionFut3 = newFuture[bool]()
    var completionFut4 = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
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
    node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), some(relayHandler))
    await sleepAsync(2000.millis)

    ## node1 publishes and relays 4 messages to node2
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    ## node2 relays either of wm1 or wm2 to node3, depending on which message arrives at node2 first
    ## node2 should detect either of wm1 or wm2 as spam and not relay it
    ## node2 should relay wm3 to node3
    ## node2 should not relay wm4 because it has no valid rln proof
    discard await node1.publish(some(DefaultPubsubTopic), wm1)
    discard await node1.publish(some(DefaultPubsubTopic), wm2)
    discard await node1.publish(some(DefaultPubsubTopic), wm3)
    discard await node1.publish(some(DefaultPubsubTopic), wm4)
    await sleepAsync(2000.millis)

    let
      res1 = await completionFut1.withTimeout(10.seconds)
      res2 = await completionFut2.withTimeout(10.seconds)

    check:
      (res1 and res2) == false
        # either of the wm1 and wm2 is found as spam hence not relayed
      (await completionFut3.withTimeout(10.seconds)) == true
      (await completionFut4.withTimeout(10.seconds)) == false

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "clearNullifierLog: should clear epochs > MaxEpochGap":
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

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up 2 nodes
    # node1
    await node1.mountRelay(@[DefaultNsPubsubTopic])

    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_10"),
      )
    else:
      let wakuRlnConfig1 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(1.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_10"),
      )
    await node1.mountRlnRelay(wakuRlnConfig1)

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultNsPubsubTopic])

    # mount rlnrelay in off-chain mode
    when defined(rln_v2):
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_11"),
      )
    else:
      let wakuRlnConfig2 = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(2.uint),
        rlnEpochSizeSec: 1,
        rlnRelayTreePath: genTempPath("rln_tree", "wakunode_11"),
      )
    await node2.mountRlnRelay(wakuRlnConfig2)

    await node2.start()

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # get the current epoch time
    let time = epochTime()
    #  create some messages with rate limit proofs
    var
      wm1 = WakuMessage(payload: "message 1".toBytes(), contentTopic: contentTopic)
      # another message in the same epoch as wm1, it will break the messaging rate limit
      wm2 = WakuMessage(payload: "message 2".toBytes(), contentTopic: contentTopic)
      #  wm3 points to the next epoch
      wm3 = WakuMessage(payload: "message 3".toBytes(), contentTopic: contentTopic)

    node1.wakuRlnRelay.unsafeAppendRLNProof(wm1, time).isOkOr:
      raiseAssert $error
    node1.wakuRlnRelay.unsafeAppendRLNProof(wm2, time).isOkOr:
      raiseAssert $error

    node1.wakuRlnRelay.unsafeAppendRLNProof(
      wm3, time + float64(node1.wakuRlnRelay.rlnEpochSizeSec * 2)
    ).isOkOr:
      raiseAssert $error

    #  relay handler for node2
    var completionFut1 = newFuture[bool]()
    var completionFut2 = newFuture[bool]()
    var completionFut3 = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      debug "The received topic:", topic
      if topic == DefaultPubsubTopic:
        if msg == wm1:
          completionFut1.complete(true)
        if msg == wm2:
          completionFut2.complete(true)
        if msg == wm3:
          completionFut3.complete(true)

    # mount the relay handler for node2
    node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), some(relayHandler))
    await sleepAsync(2000.millis)

    discard await node1.publish(some(DefaultPubsubTopic), wm1)
    discard await node1.publish(some(DefaultPubsubTopic), wm2)
    discard await node1.publish(some(DefaultPubsubTopic), wm3)

    let
      res1 = await completionFut1.withTimeout(10.seconds)
      res2 = await completionFut2.withTimeout(10.seconds)
      res3 = await completionFut3.withTimeout(10.seconds)

    check:
      res1 == true
      res2 == false
      res3 == true
      node2.wakuRlnRelay.nullifierLog.len() == 2

    await node1.stop()
    await node2.stop()
