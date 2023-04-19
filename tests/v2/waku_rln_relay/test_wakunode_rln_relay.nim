{.used.}

import
  std/sequtils,
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
  ../../../waku/v2/waku_node,
  ../../../waku/v2/waku_core,
  ../../../waku/v2/waku_rln_relay,
  ../../../waku/v2/waku_keystore,
  ../../../waku/v2/utils/peers,
  ../testlib/wakucore,
  ../testlib/wakunode

from std/times import epochTime


const RlnRelayPubsubTopic = "waku/2/rlnrelay/proto"

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

      rlnRelayPubSubTopic = RlnRelayPubsubTopic
      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])

    # mount rlnrelay in off-chain mode
    await node1.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(1)),
    ))

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])
    # mount rlnrelay in off-chain mode
    await node2.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(2)),
    ))

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])

    await node3.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(3)),
    ))

    await node3.start()

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
        debug "The received topic:", topic
        if topic == rlnRelayPubSubTopic:
          completionFut.complete(true)

    # mount the relay handler
    node3.subscribe(rlnRelayPubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "Hello".toBytes()

    # prepare the epoch
    var message = WakuMessage(payload: @payload, contentTopic: contentTopic)
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
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(0))

      rlnRelayPubSubTopic = RlnRelayPubsubTopic
      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])

    # mount rlnrelay in off-chain mode
    await node1.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(1)),
    ))

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])
    # mount rlnrelay in off-chain mode
    await node2.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(2)),
    ))

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])

    await node3.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(3)),
    ))

    await node3.start()

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # define a custom relay handler
    var completionFut = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isOk():
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
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(0))

      rlnRelayPubSubTopic = RlnRelayPubsubTopic
      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    await node1.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])

    # mount rlnrelay in off-chain mode
    await node1.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(1)),
    ))

    await node1.start()

    # node 2
    await node2.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])

    # mount rlnrelay in off-chain mode
    await node2.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(2)),
    ))

    await node2.start()

    # node 3
    await node3.mountRelay(@[DefaultPubsubTopic, rlnRelayPubSubTopic])

    # mount rlnrelay in off-chain mode
    await node3.mountRlnRelay(WakuRlnConfig(rlnRelayDynamic: false,
      rlnRelayPubsubTopic: rlnRelayPubSubTopic,
      rlnRelayContentTopic: contentTopic,
      rlnRelayMembershipIndex: some(MembershipIndex(3)),
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
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
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
      (res1 and res2) == false # either of the wm1 and wm2 is found as spam hence not relayed
      (await completionFut3.withTimeout(10.seconds)) == true
      (await completionFut4.withTimeout(10.seconds)) == false

    await node1.stop()
    await node2.stop()
    await node3.stop()
