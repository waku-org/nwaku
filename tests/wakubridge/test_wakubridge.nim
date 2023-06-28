{.used.}

import
  std/[sequtils, strutils, tables],
  stew/[results, byteutils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  eth/p2p,
  eth/keys
import
  ../../waku/v1/protocol/waku_protocol,
  ../../waku/v2/waku_core,
  ../../waku/v2/waku_node,
  ../../waku/v2/waku_enr,
  ../../waku/v2/utils/compat,
  ../test_helpers

import
  ../../apps/wakubridge/wakubridge


procSuite "WakuBridge":
  ###############
  # Suite setup #
  ###############

  const DefaultBridgeTopic = "/waku/2/default-bridge/proto"

  let
    rng = keys.newRng()
    cryptoRng = crypto.newRng()

    # Bridge
    nodev1Key = keys.KeyPair.random(rng[])
    nodev2Key = crypto.PrivateKey.random(Secp256k1, cryptoRng[])[]
    bridge = WakuBridge.new(
        nodev1Key= nodev1Key,
        nodev1Address = localAddress(62200),
        powRequirement = 0.002,
        rng = rng,
        nodev2Key = nodev2Key,
        nodev2BindIp = ValidIpAddress.init("0.0.0.0"), nodev2BindPort= Port(62201),
        nodev2PubsubTopic = DefaultBridgeTopic)

    # Waku v1 node
    v1Node = setupTestNode(rng, Waku)

    # Waku v2 node
    v2NodeKey = crypto.PrivateKey.random(Secp256k1, cryptoRng[])[]

  var builder = EnrBuilder.init(v2NodeKey)
  builder.withIpAddressAndPorts(none(ValidIpAddress), none(Port), none(Port))
  let record = builder.build().tryGet()

  let
    v2Node = block:
      var builder = WakuNodeBuilder.init()
      builder.withNodeKey(v2NodeKey)
      builder.withRecord(record)
      builder.withNetworkConfigurationDetails(ValidIpAddress.init("0.0.0.0"), Port(62203)).tryGet()
      builder.build().tryGet()

    contentTopic = ContentTopic("/waku/1/0x1a2b3c4d/rfc26")
    topic = [byte 0x1a, byte 0x2b, byte 0x3c, byte 0x4d]
    payloadV1 = "hello from V1".toBytes()
    payloadV2 = "hello from V2".toBytes()
    encodedPayloadV2 = Payload(payload: payloadV2, dst: some(nodev1Key.pubKey))
    message = WakuMessage(payload: encodedPayloadV2.encode(1, rng[]).get(), contentTopic: contentTopic, version: 1)


  ########################
  # Tests setup/teardown #
  ########################

  # setup:
  #   # Runs before each test

  # teardown:
  #   # Runs after each test

  ###############
  # Suite tests #
  ###############

  asyncTest "Messages are bridged between Waku v1 and Waku v2":
    # Setup test

    waitFor bridge.start()

    waitFor v2Node.start()
    await v2Node.mountRelay(@[DefaultBridgeTopic])
    v2Node.wakuRelay.triggerSelf = false

    discard waitFor v1Node.rlpxConnect(newNode(bridge.nodev1.toENode()))
    waitFor waku_node.connectToNodes(v2Node, @[bridge.nodev2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()

    proc relayHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      if msg.version == 1:
        check:
          # Message fields are as expected
          msg.contentTopic == contentTopic # Topic translation worked
          string.fromBytes(msg.payload).contains("from V1")

        completionFut.complete(true)

    v2Node.subscribe(DefaultBridgeTopic, relayHandler)

    # Test bridging from V2 to V1
    await v2Node.publish(DefaultBridgeTopic, message)

    await sleepAsync(1.seconds)

    check:
      # v1Node received message published by v2Node
      v1Node.protocolState(Waku).queue.items.len == 1

    let
      msg = v1Node.protocolState(Waku).queue.items[0]
      decodedPayload = msg.env.data.decode(some(nodev1Key.seckey), none[SymKey]()).get()

    check:
      # Message fields are as expected
      msg.env.topic == topic # Topic translation worked
      string.fromBytes(decodedPayload.payload).contains("from V2")

    # Test bridging from V1 to V2
    check:
      v1Node.postMessage(ttl = 5,
                         topic = topic,
                         payload = payloadV1) == true

      # v2Node received payload published by v1Node
      await completionFut.withTimeout(5.seconds)

    # Test filtering of WakuMessage duplicates
    v1Node.resetMessageQueue()

    await v2Node.publish(DefaultBridgeTopic, message)

    await sleepAsync(1.seconds)

    check:
      # v1Node did not receive duplicate of previous message
      v1Node.protocolState(Waku).queue.items.len == 0

    # Teardown test

    bridge.nodeV1.resetMessageQueue()
    v1Node.resetMessageQueue()
    waitFor allFutures([bridge.stop(), v2Node.stop()])

  asyncTest "Bridge manages its v1 connections":
    # Given
    let
      # Waku v1 node
      v1NodePool = @[setupTestNode(rng, Waku),
                     setupTestNode(rng, Waku),
                     setupTestNode(rng, Waku)]
      targetV1Peers = v1NodePool.len() - 1

      # Bridge
      v1Bridge = WakuBridge.new(
          nodev1Key= nodev1Key,
          nodev1Address = localAddress(62210),
          powRequirement = 0.002,
          rng = rng,
          nodev2Key = nodev2Key,
          nodev2BindIp = ValidIpAddress.init("0.0.0.0"), nodev2BindPort= Port(62211),
          nodev2PubsubTopic = DefaultBridgeTopic,
          v1Pool = v1NodePool.mapIt(newNode(it.toEnode())),
          targetV1Peers = targetV1Peers)

    for node in v1NodePool:
      node.startListening()

    # When
    waitFor v1Bridge.start()
    await sleepAsync(250.millis) # Give peers some time to connect

    # Then
    check:
      v1Bridge.nodev1.peerPool.connectedNodes.len() == targetV1Peers

    # When
    let connected = v1Bridge.nodev1.peerPool.connectedNodes
    for peer in connected.values():
      waitFor peer.disconnect(SubprotocolReason)

    # Then
    check:
      v1Bridge.nodev1.peerPool.connectedNodes.len() == 0

    # When
    discard v1Bridge.maintenanceLoop() # Forces one more run of the maintenance loop
    await sleepAsync(250.millis) # Give peers some time to connect

    # Then
    check:
      v1Bridge.nodev1.peerPool.connectedNodes.len() == targetV1Peers

    # Cleanup
    v1Bridge.nodev1.resetMessageQueue()

    for node in v1NodePool:
      node.resetMessageQueue()

    waitFor v1Bridge.stop()
