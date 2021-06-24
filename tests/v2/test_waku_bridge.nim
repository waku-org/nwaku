{.used.}

import
  std/strutils,
  testutils/unittests,
  chronicles, chronos, stew/shims/net as stewNet, stew/[byteutils, objects],
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  eth/p2p,
  eth/keys,
  ../../waku/common/wakubridge,
  ../../waku/v1/protocol/waku_protocol,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../../waku/v2/node/[wakunode2, waku_payload],
  ../test_helpers

procSuite "WakuBridge":
  ###############
  # Suite setup #
  ###############

  const DefaultBridgeTopic = "/waku/2/default-bridge/proto"

  let
    rng = keys.newRng()

    # Bridge
    nodev1Key = keys.KeyPair.random(rng[])
    nodev2Key = crypto.PrivateKey.random(Secp256k1, rng[])[]
    bridge = WakuBridge.new(
        nodev1Key= nodev1Key,
        nodev1Address = localAddress(30303),
        powRequirement = 0.002,
        rng = rng,
        nodev2Key = nodev2Key,
        nodev2BindIp = ValidIpAddress.init("0.0.0.0"), nodev2BindPort= Port(60000),
        nodev2PubsubTopic = DefaultBridgeTopic)
    
    # Waku v1 node
    v1Node = setupTestNode(rng, Waku)

    # Waku v2 node
    v2NodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
    v2Node = WakuNode.init(v2NodeKey, ValidIpAddress.init("0.0.0.0"), Port(60002))

    contentTopic = ContentTopic("/waku/1/1a2b3c4d/rlp")
    topic = [byte 0x1a, byte 0x2b, byte 0x3c, byte 0x4d]
    payloadV1 = "hello from V1".toBytes()
    payloadV2 = "hello from V2".toBytes()
    message = WakuMessage(payload: payloadV2, contentTopic: contentTopic)
  
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

  asyncTest "Topics are correctly converted between Waku v1 and Waku v2":
    # Expected cases
    
    check:
      toV1Topic(ContentTopic("/waku/1/00000000/rlp")) == [byte 0x00, byte 0x00, byte 0x00, byte 0x00]
      toV2ContentTopic([byte 0x00, byte 0x00, byte 0x00, byte 0x00]) == ContentTopic("/waku/1/00000000/rlp")
      toV1Topic(ContentTopic("/waku/1/ffffffff/rlp")) == [byte 0xff, byte 0xff, byte 0xff, byte 0xff]
      toV2ContentTopic([byte 0xff, byte 0xff, byte 0xff, byte 0xff]) == ContentTopic("/waku/1/ffffffff/rlp")
      toV1Topic(ContentTopic("/waku/1/1a2b3c4d/rlp")) == [byte 0x1a, byte 0x2b, byte 0x3c, byte 0x4d]
      toV2ContentTopic([byte 0x1a, byte 0x2b, byte 0x3c, byte 0x4d]) == ContentTopic("/waku/1/1a2b3c4d/rlp")
    
    # Invalid cases
    
    expect ValueError:
      # Content topic not namespaced
      discard toV1Topic(ContentTopic("this-is-my-content"))
    
    expect ValueError:
      # Content topic name too short
      discard toV1Topic(ContentTopic("/waku/1/112233/rlp"))
    
    expect ValueError:
      # Content topic name not hex
      discard toV1Topic(ContentTopic("/waku/1/my-content/rlp"))

  asyncTest "Messages are bridged between Waku v1 and Waku v2":
    # Setup test

    waitFor bridge.start()

    waitFor v2Node.start()
    v2Node.mountRelay(@[DefaultBridgeTopic])

    discard waitFor v1Node.rlpxConnect(newNode(bridge.nodev1.toENode()))
    waitFor v2Node.connectToNodes(@[bridge.nodev2.peerInfo])

    var completionFut = newFuture[bool]()

    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =      
      let msg = WakuMessage.init(data)
      
      if msg.isOk() and msg.value().version == 1:
        check:
          # Message fields are as expected
          msg.value().contentTopic == contentTopic # Topic translation worked
          string.fromBytes(msg.value().payload).contains("from V1")
        
        completionFut.complete(true)

    v2Node.subscribe(DefaultBridgeTopic, relayHandler)

    await sleepAsync(2000.millis)

    # Test bridging from V2 to V1
    await v2Node.publish(DefaultBridgeTopic, message)

    await sleepAsync(2000.millis)

    check:
      # v1Node received message published by v2Node
      v1Node.protocolState(Waku).queue.items.len == 1

    let msg = v1Node.protocolState(Waku).queue.items[0]

    check:
      # Message fields are as expected
      msg.env.topic == topic # Topic translation worked
      string.fromBytes(msg.env.data).contains("from V2")
    
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

    await sleepAsync(2000.millis)

    check:
      # v1Node did not receive duplicate of previous message
      v1Node.protocolState(Waku).queue.items.len == 0

    # Teardown test
    
    bridge.nodeV1.resetMessageQueue()
    v1Node.resetMessageQueue()
    waitFor allFutures([bridge.stop(), v2Node.stop()])
