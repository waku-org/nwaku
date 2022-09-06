{.used.}

import
  stew/byteutils, 
  stew/shims/net as stewNet, 
  testutils/unittests,
  chronicles, 
  chronos, 
  libp2p/crypto/crypto,
  libp2p/switch,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_lightpush,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2


procSuite "WakuNode - Lightpush":
  let rng = crypto.newRng()
 
  asyncTest "Lightpush message return success":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60010))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60012))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60013))

    let
      pubSubTopic = "test"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Light node, only lightpush
    await node1.start()
    await node1.mountLightPush()

    # Intermediate node
    await node2.start()
    await node2.mountRelay(@[pubSubTopic])
    await node2.mountLightPush()

    # Receiving node
    await node3.start()
    await node3.mountRelay(@[pubSubTopic])

    discard await node1.peerManager.dialPeer(node2.switch.peerInfo.toRemotePeerInfo(), WakuLightPushCodec)
    await sleepAsync(1.seconds)
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

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
    await sleepAsync(500.millis)

    proc handler(response: PushResponse) {.gcsafe, closure.} =
      debug "push response handler, expecting true"
      check:
        response.isSuccess == true
      completionFutLightPush.complete(true)

    # Publishing with lightpush
    await node1.lightpush(pubSubTopic, message, handler)
    await sleepAsync(500.millis)

    check:
      (await completionFutRelay.withTimeout(1.seconds)) == true
      (await completionFutLightPush.withTimeout(1.seconds)) == true

    await allFutures([node1.stop(), node2.stop(), node3.stop()])
  