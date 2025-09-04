{.used.}

import
  std/[options, os, sequtils, tempfiles, strutils, osproc],
  stew/byteutils,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub
import
  waku/[waku_core, waku_node, waku_rln_relay],
  ../testlib/[wakucore, futures, wakunode, testutils],
  ./utils_onchain,
  ./rln/waku_rln_relay_utils

from std/times import epochTime

proc getWakuRlnConfig(
    manager: OnchainGroupManager,
    userMessageLimit: uint64 = 1,
    epochSizeSec: uint64 = 1,
    treePath: string = genTempPath("rln_tree", "wakunode_rln_relay"),
    index: MembershipIndex = MembershipIndex(0),
): WakuRlnConfig =
  let wakuRlnConfig = WakuRlnConfig(
    dynamic: true,
    ethClientUrls: @[EthClient],
    ethContractAddress: manager.ethContractAddress,
    chainId: manager.chainId,
    credIndex: some(index),
    userMessageLimit: userMessageLimit,
    epochSizeSec: epochSizeSec,
    treePath: treePath,
    ethPrivateKey: some(manager.ethPrivateKey.get()),
    onFatalErrorAction: proc(errStr: string) =
      warn "non-fatal onchain test error", errStr = errStr
    ,
  )
  return wakuRlnConfig

proc waitForNullifierLog(node: WakuNode, expectedLen: int): Future[bool] {.async.} =
  ## Helper function
  for i in 0 .. 100: # Try for up to 50 seconds (100 * 500ms)
    if node.wakuRlnRelay.nullifierLog.len() == expectedLen:
      return true
    await sleepAsync(500.millis)
  return false

procSuite "WakuNode - RLN relay":
  # NOTE: we set the rlnRelayUserMessageLimit to 1 to make the tests easier to reason about
  var anvilProc: Process
  var tempManager: ptr OnchainGroupManager

  setup:
    anvilProc = runAnvil()
    tempManager =
      cast[ptr OnchainGroupManager](allocShared0(sizeof(OnchainGroupManager)))
    tempManager[] = waitFor setupOnchainGroupManager()

  teardown:
    if not tempManager.isNil:
      try:
        waitFor tempManager[].stop()
      except CatchableError:
        discard
      freeShared(tempManager)
    stopAnvil(anvilProc)

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
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # mount rlnrelay in off-chain mode
    let wakuRlnConfig1 = getWakuRlnConfig(
      manager = tempManager[],
      treePath = genTempPath("rln_tree", "wakunode_1"),
      index = MembershipIndex(1),
    )

    await node1.mountRlnRelay(wakuRlnConfig1)
    await node1.start()

    # Registration is mandatory before sending messages with rln-relay 
    let manager1 = cast[OnchainGroupManager](node1.wakuRlnRelay.groupManager)
    let idCredentials1 = generateCredentials(manager1.rlnInstance)

    try:
      waitFor manager1.register(idCredentials1, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let rootUpdated1 = waitFor manager1.updateRoots()
    debug "Updated root for node1", rootUpdated1

    # node 2
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    # mount rlnrelay in off-chain mode
    let wakuRlnConfig2 = getWakuRlnConfig(
      manager = tempManager[],
      treePath = genTempPath("rln_tree", "wakunode_2"),
      index = MembershipIndex(2),
    )

    await node2.mountRlnRelay(wakuRlnConfig2)
    await node2.start()

    let manager2 = cast[OnchainGroupManager](node2.wakuRlnRelay.groupManager)
    let rootUpdated2 = waitFor manager2.updateRoots()
    debug "Updated root for node2", rootUpdated2

    # node 3
    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let wakuRlnConfig3 = getWakuRlnConfig(
      manager = tempManager[],
      treePath = genTempPath("rln_tree", "wakunode_3"),
      index = MembershipIndex(3),
    )

    await node3.mountRlnRelay(wakuRlnConfig3)
    await node3.start()

    let manager3 = cast[OnchainGroupManager](node3.wakuRlnRelay.groupManager)
    let rootUpdated3 = waitFor manager3.updateRoots()
    debug "Updated root for node3", rootUpdated3

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

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node1.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node1: " & $error
    node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node2: " & $error

    ## Subscribe to the relay topic to add the custom relay handler defined above
    node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "Hello".toBytes()

    # prepare the epoch
    var message =
      WakuMessage(payload: @payload, contentTopic: contentTopic, timestamp: now())
    doAssert(
      node1.wakuRlnRelay
      .unsafeAppendRLNProof(message, node1.wakuRlnRelay.getCurrentEpoch(), MessageId(0))
      .isOk()
    )

    debug " Nodes participating in the test",
      node1 = shortLog(node1.switch.peerInfo.peerId),
      node2 = shortLog(node2.switch.peerInfo.peerId),
      node3 = shortLog(node3.switch.peerInfo.peerId)

    ## node1 publishes a message with a rate limit proof, the message is then relayed to node2 which in turn
    ## verifies the rate limit proof of the message and relays the message to node3
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    discard await node1.publish(some(DefaultPubsubTopic), message)
    assert (await completionFut.withTimeout(15.seconds)), "completionFut timed out"

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "testing rln-relay is applied in all rln shards/content topics":
    # create 3 nodes
    let nodes = toSeq(0 ..< 3).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )
    await allFutures(nodes.mapIt(it.start()))

    let shards =
      @[RelayShard(clusterId: 0, shardId: 0), RelayShard(clusterId: 0, shardId: 1)]
    let contentTopics =
      @[
        ContentTopic("/waku/2/content-topic-a/proto"),
        ContentTopic("/waku/2/content-topic-b/proto"),
      ]

    # set up three nodes
    await allFutures(nodes.mapIt(it.mountRelay()))

    # mount rlnrelay in off-chain mode
    for index, node in nodes:
      let wakuRlnConfig = getWakuRlnConfig(
        manager = tempManager[],
        treePath = genTempPath("rln_tree", "wakunode_" & $(index + 1)),
        index = MembershipIndex(index + 1),
      )

      await node.mountRlnRelay(wakuRlnConfig)
      await node.start()
      let manager = cast[OnchainGroupManager](node.wakuRlnRelay.groupManager)
      let idCredentials = generateCredentials(manager.rlnInstance)

      try:
        waitFor manager.register(idCredentials, UserMessageLimit(20))
      except Exception, CatchableError:
        assert false,
          "exception raised when calling register: " & getCurrentExceptionMsg()

      let rootUpdated = waitFor manager.updateRoots()
      debug "Updated root for node", node = index + 1, rootUpdated = rootUpdated

    # connect them together
    await nodes[0].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])
    await nodes[2].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])

    var rxMessagesTopic1 = 0
    var rxMessagesTopic2 = 0
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      info "relayHandler. The received topic:", topic
      if topic == $shards[0]:
        rxMessagesTopic1 = rxMessagesTopic1 + 1
      elif topic == $shards[1]:
        rxMessagesTopic2 = rxMessagesTopic2 + 1

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    nodes[0].subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in nodes[0]: " & $error
    nodes[1].subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in nodes[1]: " & $error

    # mount the relay handlers
    nodes[2].subscribe((kind: PubsubSub, topic: $shards[0]), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    nodes[2].subscribe((kind: PubsubSub, topic: $shards[1]), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    await sleepAsync(1000.millis)

    # generate some messages with rln proofs first. generating
    # the proof takes some time, so this is done before publishing
    # to avoid blocking the test
    var messages1: seq[WakuMessage] = @[]
    var messages2: seq[WakuMessage] = @[]

    for i in 0 ..< 3:
      var message = WakuMessage(
        payload: ("Payload_" & $i).toBytes(),
        timestamp: now(),
        contentTopic: contentTopics[0],
      )
      nodes[0].wakuRlnRelay.unsafeAppendRLNProof(
        message, nodes[0].wakuRlnRelay.getCurrentEpoch(), MessageId(i.uint8)
      ).isOkOr:
        raiseAssert $error
      messages1.add(message)

    for i in 0 ..< 3:
      var message = WakuMessage(
        payload: ("Payload_" & $i).toBytes(),
        timestamp: now(),
        contentTopic: contentTopics[1],
      )
      nodes[1].wakuRlnRelay.unsafeAppendRLNProof(
        message, nodes[1].wakuRlnRelay.getCurrentEpoch(), MessageId(i.uint8)
      ).isOkOr:
        raiseAssert $error
      messages2.add(message)

    # publish 3 messages from node[0] (last 2 are spam, window is 10 secs)
    # publish 3 messages from node[1] (last 2 are spam, window is 10 secs)
    for msg in messages1:
      discard await nodes[0].publish(some($shards[0]), msg)
    for msg in messages2:
      discard await nodes[1].publish(some($shards[1]), msg)

    # wait for gossip to propagate
    await sleepAsync(5000.millis)

    # check that node[2] got messages from both topics
    # and that rln was applied (just 1 msg is rx, rest are spam)
    check:
      rxMessagesTopic1 == 3
      rxMessagesTopic2 == 3

    await allFutures(nodes.mapIt(it.stop()))

  # asyncTest "testing rln-relay with invalid proof":
  #   let
  #     # publisher node
  #     nodeKey1 = generateSecp256k1Key()
  #     node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
  #     # Relay node
  #     nodeKey2 = generateSecp256k1Key()
  #     node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
  #     # Subscriber
  #     nodeKey3 = generateSecp256k1Key()
  #     node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))

  #     contentTopic = ContentTopic("/waku/2/default-content/proto")

  #   # set up three nodes
  #   # node1
  #   (await node1.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"

  #   # mount rlnrelay in off-chain mode
  #   let wakuRlnConfig1 = getWakuRlnConfig(
  #     manager = tempManager[],
  #     treePath = genTempPath("rln_tree", "wakunode_1"),
  #     index = MembershipIndex(1),
  #   )

  #   await node1.mountRlnRelay(wakuRlnConfig1)
  #   await node1.start()

  #   let manager1 = cast[OnchainGroupManager](node1.wakuRlnRelay.groupManager)
  #   let idCredentials1 = generateCredentials(manager1.rlnInstance)

  #   try:
  #     waitFor manager1.register(idCredentials1, UserMessageLimit(20))
  #   except Exception, CatchableError:
  #     assert false,
  #       "exception raised when calling register: " & getCurrentExceptionMsg()

  #   let rootUpdated1 = waitFor manager1.updateRoots()
  #   debug "Updated root for node1", rootUpdated1

  #   # node 2
  #   (await node2.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"
  #   # mount rlnrelay in off-chain mode
  #   let wakuRlnConfig2 = getWakuRlnConfig(
  #     manager = tempManager[],
  #     treePath = genTempPath("rln_tree", "wakunode_2"),
  #     index = MembershipIndex(2),
  #   )

  #   await node2.mountRlnRelay(wakuRlnConfig2)
  #   await node2.start()

  #   let manager2 = cast[OnchainGroupManager](node2.wakuRlnRelay.groupManager)
  #   let rootUpdated2 = waitFor manager2.updateRoots()
  #   debug "Updated root for node2", rootUpdated2

  #   # node 3
  #   (await node3.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"

  #   let wakuRlnConfig3 = getWakuRlnConfig(
  #     manager = tempManager[],
  #     treePath =  genTempPath("rln_tree", "wakunode_3"),
  #     index = MembershipIndex(3),
  #   )

  #   await node3.mountRlnRelay(wakuRlnConfig3)
  #   await node3.start()

  #   let manager3 = cast[OnchainGroupManager](node3.wakuRlnRelay.groupManager)
  #   let rootUpdated3 = waitFor manager3.updateRoots()
  #   debug "Updated root for node3", rootUpdated3

  #   # connect them together
  #   await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
  #   await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

  #   # define a custom relay handler
  #   var completionFut = newFuture[bool]()
  #   proc relayHandler(
  #       topic: PubsubTopic, msg: WakuMessage
  #   ): Future[void] {.async, gcsafe.} =
  #     debug "The received topic:", topic
  #     if topic == DefaultPubsubTopic:
  #       completionFut.complete(true)

  #   proc simpleHandler(
  #       topic: PubsubTopic, msg: WakuMessage
  #   ): Future[void] {.async, gcsafe.} =
  #     await sleepAsync(0.milliseconds)

  #   node1.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic in node1: " & $error
  #   node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic in node2: " & $error

  #   # mount the relay handler
  #   node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic: " & $error
  #   await sleepAsync(2000.millis)

  #   # prepare the message payload
  #   let payload = "Hello".toBytes()

  #   # prepare the epoch
  #   let epoch = node1.wakuRlnRelay.getCurrentEpoch()

  #   # prepare the proof
  #   let
  #     contentTopicBytes = contentTopic.toBytes
  #     input = concat(payload, contentTopicBytes)
  #     extraBytes: seq[byte] = @[byte(1), 2, 3]

  #   let nonceManager = node1.wakuRlnRelay.nonceManager
  #   let rateLimitProofRes = node1.wakuRlnRelay.groupManager.generateProof(
  #     concat(input, extraBytes), epoch, MessageId(0)
  #   )

  #   assert rateLimitProofRes.isOk(), $rateLimitProofRes.error
  #     # check the proof is generated correctly outside when block to avoid duplication
  #   let rateLimitProof = rateLimitProofRes.get().encode().buffer

  #   let message = WakuMessage(
  #     payload: @payload,
  #     contentTopic: contentTopic,
  #     proof: rateLimitProof,
  #     timestamp: now(),
  #   )

  #   ## node1 publishes a message with an invalid rln proof, the message is then relayed to node2 which in turn
  #   ## attempts to verify the rate limit proof and fails hence does not relay the message to node3, thus the relayHandler of node3
  #   ## never gets called
  #   ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
  #   discard await node1.publish(some(DefaultPubsubTopic), message)
  #   await sleepAsync(2000.millis)

  #   check:
  #     # the relayHandler of node3 never gets called
  #     (await completionFut.withTimeout(10.seconds)) == false

  #   await node1.stop()
  #   await node2.stop()
  #   await node3.stop()

  # asyncTest "testing rln-relay double-signaling detection":
  #   let
  #     # publisher node
  #     nodeKey1 = generateSecp256k1Key()
  #     node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
  #     # Relay node
  #     nodeKey2 = generateSecp256k1Key()
  #     node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
  #     # Subscriber
  #     nodeKey3 = generateSecp256k1Key()
  #     node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))

  #     contentTopic = ContentTopic("/waku/2/default-content/proto")

  #   # set up three nodes
  #   # node1
  #   (await node1.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"

  #   # mount rlnrelay in off-chain mode
  #   let wakuRlnConfig1 = WakuRlnConfig(
  #     dynamic: false,
  #     credIndex: some(1.uint),
  #     userMessageLimit: 1,
  #     epochSizeSec: 1,
  #     treePath: genTempPath("rln_tree", "wakunode_7"),
  #   )

  #   await node1.mountRlnRelay(wakuRlnConfig1)

  #   await node1.start()

  #   # node 2
  #   (await node2.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"

  #   # mount rlnrelay in off-chain mode
  #   let wakuRlnConfig2 = WakuRlnConfig(
  #     dynamic: false,
  #     credIndex: some(2.uint),
  #     userMessageLimit: 1,
  #     epochSizeSec: 1,
  #     treePath: genTempPath("rln_tree", "wakunode_8"),
  #   )

  #   await node2.mountRlnRelay(wakuRlnConfig2)
  #   await node2.start()

  #   # node 3
  #   (await node3.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"

  #   # mount rlnrelay in off-chain mode
  #   let wakuRlnConfig3 = WakuRlnConfig(
  #     dynamic: false,
  #     credIndex: some(3.uint),
  #     userMessageLimit: 1,
  #     epochSizeSec: 1,
  #     treePath: genTempPath("rln_tree", "wakunode_9"),
  #   )

  #   await node3.mountRlnRelay(wakuRlnConfig3)

  #   await node3.start()

  #   # connect the nodes together node1 <-> node2 <-> node3
  #   await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
  #   await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

  #   # get the current epoch time
  #   let time_1 = epochTime()

  #   #  create some messages with rate limit proofs
  #   var
  #     wm1 = WakuMessage(
  #       payload: "message 1".toBytes(), timestamp: now(), contentTopic: contentTopic
  #     )
  #     # another message in the same epoch as wm1, it will break the messaging rate limit
  #     wm2 = WakuMessage(
  #       payload: "message 2".toBytes(), timestamp: now(), contentTopic: contentTopic
  #     )
  #     #  wm3 points to the next epoch

  #   await sleepAsync(1000.millis)
  #   let time_2 = epochTime()

  #   var
  #     wm3 = WakuMessage(
  #       payload: "message 3".toBytes(), timestamp: now(), contentTopic: contentTopic
  #     )
  #     wm4 = WakuMessage(
  #       payload: "message 4".toBytes(), timestamp: now(), contentTopic: contentTopic
  #     )

  #   node3.wakuRlnRelay.unsafeAppendRLNProof(wm1, time_1).isOkOr:
  #     raiseAssert $error
  #   node3.wakuRlnRelay.unsafeAppendRLNProof(wm2, time_1).isOkOr:
  #     raiseAssert $error

  #   node3.wakuRlnRelay.unsafeAppendRLNProof(wm3, time_2).isOkOr:
  #     raiseAssert $error

  #   #  relay handler for node3
  #   var completionFut1 = newFuture[bool]()
  #   var completionFut2 = newFuture[bool]()
  #   var completionFut3 = newFuture[bool]()
  #   var completionFut4 = newFuture[bool]()
  #   proc relayHandler(
  #       topic: PubsubTopic, msg: WakuMessage
  #   ): Future[void] {.async, gcsafe.} =
  #     debug "The received topic:", topic
  #     if topic == DefaultPubsubTopic:
  #       if msg == wm1:
  #         completionFut1.complete(true)
  #       if msg == wm2:
  #         completionFut2.complete(true)
  #       if msg.payload == wm3.payload:
  #         completionFut3.complete(true)
  #       if msg.payload == wm4.payload:
  #         completionFut4.complete(true)

  #   proc simpleHandler(
  #       topic: PubsubTopic, msg: WakuMessage
  #   ): Future[void] {.async, gcsafe.} =
  #     await sleepAsync(0.milliseconds)

  #   node1.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic in node1: " & $error
  #   node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic in node2: " & $error

  #   # mount the relay handler for node3
  #   node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic: " & $error
  #   await sleepAsync(2000.millis)

  #   ## node1 publishes and relays 4 messages to node2
  #   ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
  #   ## node2 relays either of wm1 or wm2 to node3, depending on which message arrives at node2 first
  #   ## node2 should detect either of wm1 or wm2 as spam and not relay it
  #   ## node2 should relay wm3 to node3
  #   ## node2 should not relay wm4 because it has no valid rln proof
  #   discard await node1.publish(some(DefaultPubsubTopic), wm1)
  #   discard await node1.publish(some(DefaultPubsubTopic), wm2)
  #   discard await node1.publish(some(DefaultPubsubTopic), wm3)
  #   discard await node1.publish(some(DefaultPubsubTopic), wm4)
  #   await sleepAsync(2000.millis)

  #   let
  #     res1 = await completionFut1.withTimeout(10.seconds)
  #     res2 = await completionFut2.withTimeout(10.seconds)

  #   check:
  #     (res1 and res2) == false
  #       # either of the wm1 and wm2 is found as spam hence not relayed
  #     (await completionFut3.withTimeout(10.seconds)) == true
  #     (await completionFut4.withTimeout(10.seconds)) == false

  #   await node1.stop()
  #   await node2.stop()
  #   await node3.stop()

  # xasyncTest "clearNullifierLog: should clear epochs > MaxEpochGap":
  #   ## This is skipped because is flaky and made CI randomly fail but is useful to run manually
  #   # Given two nodes
  #   let
  #     contentTopic = ContentTopic("/waku/2/default-content/proto")
  #     shardSeq = @[DefaultRelayShard]
  #     nodeKey1 = generateSecp256k1Key()
  #     node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
  #     nodeKey2 = generateSecp256k1Key()
  #     node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
  #     epochSizeSec: uint64 = 5 # This means rlnMaxEpochGap = 4

  #   # Given both nodes mount relay and rlnrelay
  #   (await node1.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"
  #   let wakuRlnConfig1 = buildWakuRlnConfig(1, epochSizeSec, "wakunode_10")
  #   (await node1.mountRlnRelay(wakuRlnConfig1)).isOkOr:
  #     assert false, "Failed to mount rlnrelay"

  #   # Mount rlnrelay in node2 in off-chain mode
  #   (await node2.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"
  #   let wakuRlnConfig2 = buildWakuRlnConfig(2, epochSizeSec, "wakunode_11")
  #   await node2.mountRlnRelay(wakuRlnConfig2)

  #   # Given the two nodes are started and connected
  #   waitFor allFutures(node1.start(), node2.start())
  #   await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

  #   # Given some messages
  #   var
  #     wm1 = WakuMessage(payload: "message 1".toBytes(), contentTopic: contentTopic)
  #     wm2 = WakuMessage(payload: "message 2".toBytes(), contentTopic: contentTopic)
  #     wm3 = WakuMessage(payload: "message 3".toBytes(), contentTopic: contentTopic)
  #     wm4 = WakuMessage(payload: "message 4".toBytes(), contentTopic: contentTopic)
  #     wm5 = WakuMessage(payload: "message 5".toBytes(), contentTopic: contentTopic)
  #     wm6 = WakuMessage(payload: "message 6".toBytes(), contentTopic: contentTopic)

  #   # And node2 mounts a relay handler that completes the respective future when a message is received
  #   var
  #     completionFut1 = newFuture[bool]()
  #     completionFut2 = newFuture[bool]()
  #     completionFut3 = newFuture[bool]()
  #     completionFut4 = newFuture[bool]()
  #     completionFut5 = newFuture[bool]()
  #     completionFut6 = newFuture[bool]()
  #   proc relayHandler(
  #       topic: PubsubTopic, msg: WakuMessage
  #   ): Future[void] {.async, gcsafe.} =
  #     debug "The received topic:", topic
  #     if topic == DefaultPubsubTopic:
  #       if msg == wm1:
  #         completionFut1.complete(true)
  #       if msg == wm2:
  #         completionFut2.complete(true)
  #       if msg == wm3:
  #         completionFut3.complete(true)
  #       if msg == wm4:
  #         completionFut4.complete(true)
  #       if msg == wm5:
  #         completionFut5.complete(true)
  #       if msg == wm6:
  #         completionFut6.complete(true)

  #   node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic: " & $error

  #   # Given all messages have an rln proof and are published by the node 1
  #   let publishSleepDuration: Duration = 5000.millis
  #   let startTime = epochTime()

  #   # Epoch 1
  #   node1.wakuRlnRelay.unsafeAppendRLNProof(wm1, startTime).isOkOr:
  #     raiseAssert $error

  #   # Message wm2 is published in the same epoch as wm1, so it'll be considered spam
  #   node1.wakuRlnRelay.unsafeAppendRLNProof(wm2, startTime).isOkOr:
  #     raiseAssert $error

  #   discard await node1.publish(some(DefaultPubsubTopic), wm1)
  #   discard await node1.publish(some(DefaultPubsubTopic), wm2)
  #   await sleepAsync(publishSleepDuration)
  #   check:
  #     await node1.waitForNullifierLog(0)
  #     await node2.waitForNullifierLog(1)

  #   # Epoch 2

  #   node1.wakuRlnRelay.unsafeAppendRLNProof(wm3, startTime + float(1 * epochSizeSec)).isOkOr:
  #     raiseAssert $error

  #   discard await node1.publish(some(DefaultPubsubTopic), wm3)

  #   await sleepAsync(publishSleepDuration)

  #   check:
  #     await node1.waitForNullifierLog(0)
  #     await node2.waitForNullifierLog(2)

  #   # Epoch 3
  #   node1.wakuRlnRelay.unsafeAppendRLNProof(wm4, startTime + float(2 * epochSizeSec)).isOkOr:
  #     raiseAssert $error

  #   discard await node1.publish(some(DefaultPubsubTopic), wm4)
  #   await sleepAsync(publishSleepDuration)
  #   check:
  #     await node1.waitForNullifierLog(0)
  #     await node2.waitForNullifierLog(3)

  #   # Epoch 4
  #   node1.wakuRlnRelay.unsafeAppendRLNProof(wm5, startTime + float(3 * epochSizeSec)).isOkOr:
  #     raiseAssert $error

  #   discard await node1.publish(some(DefaultPubsubTopic), wm5)
  #   await sleepAsync(publishSleepDuration)
  #   check:
  #     await node1.waitForNullifierLog(0)
  #     await node2.waitForNullifierLog(4)

  #   # Epoch 5
  #   node1.wakuRlnRelay.unsafeAppendRLNProof(wm6, startTime + float(4 * epochSizeSec)).isOkOr:
  #     raiseAssert $error

  #   discard await node1.publish(some(DefaultPubsubTopic), wm6)
  #   await sleepAsync(publishSleepDuration)
  #   check:
  #     await node1.waitForNullifierLog(0)
  #     await node2.waitForNullifierLog(4)

  #   # Then the node 2 should have cleared the nullifier log for epochs > MaxEpochGap
  #   # Therefore, with 4 max epochs, the first 4 messages will be published (except wm2, which shares epoch with wm1)
  #   check:
  #     (await completionFut1.waitForResult()).value() == true
  #     (await completionFut2.waitForResult()).isErr()
  #     (await completionFut3.waitForResult()).value() == true
  #     (await completionFut4.waitForResult()).value() == true
  #     (await completionFut5.waitForResult()).value() == true
  #     (await completionFut6.waitForResult()).value() == true

  #   # Cleanup
  #   waitFor allFutures(node1.stop(), node2.stop())

  # asyncTest "Spam Detection and Slashing (currently gossipsub score decrease)":
  #   # Given two nodes
  #   let
  #     contentTopic = ContentTopic("/waku/2/default-content/proto")
  #     shardSeq = @[DefaultRelayShard]
  #     nodeKey1 = generateSecp256k1Key()
  #     node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
  #     nodeKey2 = generateSecp256k1Key()
  #     node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
  #     epochSizeSec: uint64 = 5 # This means rlnMaxEpochGap = 4

  #   # Given both nodes mount relay and rlnrelay
  #   # Mount rlnrelay in node1 in off-chain mode
  #   (await node1.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"
  #   let wakuRlnConfig1 = buildWakuRlnConfig(1, epochSizeSec, "wakunode_10")
  #   await node1.mountRlnRelay(wakuRlnConfig1)

  #   # Mount rlnrelay in node2 in off-chain mode
  #   (await node2.mountRelay()).isOkOr:
  #     assert false, "Failed to mount relay"
  #   let wakuRlnConfig2 = buildWakuRlnConfig(2, epochSizeSec, "wakunode_11")
  #   await node2.mountRlnRelay(wakuRlnConfig2)

  #   proc simpleHandler(
  #       topic: PubsubTopic, msg: WakuMessage
  #   ): Future[void] {.async, gcsafe.} =
  #     await sleepAsync(0.milliseconds)

  #   node1.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic in node2: " & $error
  #   node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
  #     assert false, "Failed to subscribe to pubsub topic in node1: " & $error

  #   # Given the two nodes are started and connected
  #   waitFor allFutures(node1.start(), node2.start())
  #   await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

  #   # Given some messages with rln proofs
  #   let time = epochTime()
  #   var
  #     msg1 = WakuMessage(
  #       payload: "message 1".toBytes(), timestamp: now(), contentTopic: contentTopic
  #     )
  #     msg2 = WakuMessage(
  #       payload: "message 2".toBytes(), timestamp: now(), contentTopic: contentTopic
  #     )

  #   node1.wakuRlnRelay.unsafeAppendRLNProof(msg1, time).isOkOr:
  #     raiseAssert $error
  #   # Message wm2 is published in the same epoch as wm1, so it'll be considered spam
  #   node1.wakuRlnRelay.unsafeAppendRLNProof(msg2, time).isOkOr:
  #     raiseAssert $error

  #   # When publishing the first message (valid)
  #   discard await node1.publish(some(DefaultPubsubTopic), msg1)
  #   await sleepAsync(FUTURE_TIMEOUT_SCORING) # Wait for scoring

  #   # Then the score of node2 should increase
  #   check:
  #     node1.wakuRelay.peerStats[node2.switch.peerInfo.peerId].score == 0.1
  #     node2.wakuRelay.peerStats[node1.switch.peerInfo.peerId].score == 1.1

  #   # When publishing the second message (spam)
  #   discard await node1.publish(some(DefaultPubsubTopic), msg2)
  #   await sleepAsync(FUTURE_TIMEOUT_SCORING)

  #   # Then the score of node2 should decrease
  #   check:
  #     node1.wakuRelay.peerStats[node2.switch.peerInfo.peerId].score == 0.1
  #     node2.wakuRelay.peerStats[node1.switch.peerInfo.peerId].score == -99.4

  #   await node1.stop()
  #   await node2.stop()
