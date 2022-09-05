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
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  eth/keys
import
  ../../waku/v2/protocol/waku_rln_relay/[waku_rln_relay_utils, waku_rln_relay_types],
  ../../waku/v2/protocol/[waku_relay, waku_message],
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2

from std/times import epochTime


  
const RLNRELAY_PUBSUB_TOPIC = "waku/2/rlnrelay/proto"

procSuite "WakuNode - RLN relay":
  let rng = keys.newRng()

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
    let (groupOpt1, memKeyPairOpt1, memIndexOpt1) = rlnRelayStaticSetUp(1) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node1.mountRlnRelayStatic(group = groupOpt1.get(),
                                memKeyPair = memKeyPairOpt1.get(),
                                memIndex = memIndexOpt1.get(), 
                                pubsubTopic = rlnRelayPubSubTopic,
                                contentTopic = contentTopic)
    await node1.start()

    # node 2
    node2.mountRelay(@[rlnRelayPubSubTopic])
    let (groupOpt2, memKeyPairOpt2, memIndexOpt2) = rlnRelayStaticSetUp(2) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node2.mountRlnRelayStatic(group = groupOpt2.get(),
                                memKeyPair = memKeyPairOpt2.get(),
                                memIndex = memIndexOpt2.get(),
                                pubsubTopic = rlnRelayPubSubTopic,
                                contentTopic = contentTopic)
    await node2.start()

    # node 3
    node3.mountRelay(@[rlnRelayPubSubTopic])
    let (groupOpt3, memKeyPairOpt3, memIndexOpt3) = rlnRelayStaticSetUp(3) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node3.mountRlnRelayStatic(group = groupOpt3.get(),
                                memKeyPair = memKeyPairOpt3.get(),
                                memIndex = memIndexOpt3.get(),
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
    let (groupOpt1, memKeyPairOpt1, memIndexOpt1) = rlnRelayStaticSetUp(1) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node1.mountRlnRelayStatic(group = groupOpt1.get(),
                                memKeyPair = memKeyPairOpt1.get(),
                                memIndex = memIndexOpt1.get(),
                                pubsubTopic = rlnRelayPubSubTopic,
                                contentTopic = contentTopic)
    await node1.start()

    # node 2
    node2.mountRelay(@[rlnRelayPubSubTopic])
    let (groupOpt2, memKeyPairOpt2, memIndexOpt2) = rlnRelayStaticSetUp(2) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node2.mountRlnRelayStatic(group = groupOpt2.get(),
                                memKeyPair = memKeyPairOpt2.get(),
                                memIndex = memIndexOpt2.get(),
                                pubsubTopic = rlnRelayPubSubTopic,
                                contentTopic = contentTopic)
    await node2.start()

    # node 3
    node3.mountRelay(@[rlnRelayPubSubTopic])
    let (groupOpt3, memKeyPairOpt3, memIndexOpt3) = rlnRelayStaticSetUp(3) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node3.mountRlnRelayStatic(group = groupOpt3.get(),
                                memKeyPair = memKeyPairOpt3.get(),
                                memIndex= memIndexOpt3.get(),
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
    let (groupOpt1, memKeyPairOpt1, memIndexOpt1) = rlnRelayStaticSetUp(1) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node1.mountRlnRelayStatic(group = groupOpt1.get(),
                                memKeyPair = memKeyPairOpt1.get(),
                                memIndex = memIndexOpt1.get(),
                                pubsubTopic = rlnRelayPubSubTopic,
                                contentTopic = contentTopic)
    await node1.start()

    # node 2
    node2.mountRelay(@[rlnRelayPubSubTopic])
    let (groupOpt2, memKeyPairOpt2, memIndexOpt2) = rlnRelayStaticSetUp(2) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node2.mountRlnRelayStatic(group = groupOpt2.get(),
                                memKeyPair = memKeyPairOpt2.get(),
                                memIndex = memIndexOpt2.get(),
                                pubsubTopic = rlnRelayPubSubTopic,
                                contentTopic = contentTopic)
    await node2.start()

    # node 3
    node3.mountRelay(@[rlnRelayPubSubTopic])
    let (groupOpt3, memKeyPairOpt3, memIndexOpt3) = rlnRelayStaticSetUp(3) # set up rln relay inputs
    # mount rlnrelay in off-chain mode
    node3.mountRlnRelayStatic(group = groupOpt3.get(),
                                memKeyPair = memKeyPairOpt3.get(),
                                memIndex = memIndexOpt3.get(), 
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
      wm2 = WakuMessage(payload: "message 2".toBytes(), contentTopic: contentTopic)
      proofAdded2 = node3.wakuRlnRelay.appendRLNProof(wm2, time)
      #  wm3 points to the next epoch
      wm3 = WakuMessage(payload: "message 3".toBytes(), contentTopic: contentTopic)
      proofAdded3 = node3.wakuRlnRelay.appendRLNProof(wm3, time+EPOCH_UNIT_SECONDS)
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
      (res1 and res2) == false # either of the wm1 and wm2 is found as spam hence not relayed
      (await completionFut3.withTimeout(10.seconds)) == true
      (await completionFut4.withTimeout(10.seconds)) == false

    await node1.stop()
    await node2.stop()
    await node3.stop()