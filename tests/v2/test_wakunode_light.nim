{.used.}

import
  testutils/unittests,
  chronicles, chronos, stew/shims/net as stewNet, stew/byteutils,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  eth/keys,
  ../../waku/v2/protocol/[waku_relay, waku_message, message_notifier],
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../../waku/v2/protocol/waku_lightpush/waku_lightpush,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2,
  ../test_helpers

procSuite "WakuNode LightPush":
  let rng = keys.newRng()

  asyncTest "Lightpush message return success":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60010))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60012))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60013))
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Light node, only lightpush
    await node1.start()
    node1.mountLightPush()

    # Intermediate node
    await node2.start()
    node2.mountRelay(@[pubSubTopic])
    node2.mountLightPush()

    # Receiving node
    await node3.start()
    node3.mountRelay(@[pubSubTopic])

    discard await node1.peerManager.dialPeer(node2.peerInfo, WakuLightPushCodec)
    await sleepAsync(5.seconds)
    await node3.connectToNodes(@[node2.peerInfo])

    var completionFutLightPush = newFuture[bool]()
    var completionFutRelay = newFuture[bool]()
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFutRelay.complete(true)

    node3.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    proc handler(response: PushResponse) {.gcsafe, closure.} =
      debug "push response handler, expecting true"
      check:
        response.isSuccess == true
      completionFutLightPush.complete(true)

    # Publishing with lightpush
    await node1.lightpush(pubSubTopic, message, handler)
    await sleepAsync(2000.millis)

    check:
      (await completionFutRelay.withTimeout(5.seconds)) == true
      (await completionFutLightPush.withTimeout(5.seconds)) == true

    await allFutures([node1.stop(), node2.stop(), node3.stop()])
