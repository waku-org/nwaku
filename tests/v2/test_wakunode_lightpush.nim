{.used.}

import
  stew/shims/net as stewNet, 
  testutils/unittests,
  chronicles,
  chronos, 
  libp2p/crypto/crypto,
  libp2p/switch
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_lightpush,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/waku_node,
  ./testlib/common


procSuite "WakuNode - Lightpush":
  let rng = crypto.newRng()
 
  asyncTest "Lightpush message return success":
    ## Setup
    let
      lightNodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      lightNode = WakuNode.new(lightNodeKey, ValidIpAddress.init("0.0.0.0"), Port(60010))
      bridgeNodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      bridgeNode = WakuNode.new(bridgeNodeKey, ValidIpAddress.init("0.0.0.0"), Port(60012))
      destNodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      destNode = WakuNode.new(destNodeKey, ValidIpAddress.init("0.0.0.0"), Port(60013))

    await allFutures(destNode.start(), bridgeNode.start(), lightNode.start())

    await destNode.mountRelay(@[DefaultPubsubTopic])
    await bridgeNode.mountRelay(@[DefaultPubsubTopic])
    await bridgeNode.mountLightPush()
    lightNode.mountLightPushClient()
    
    discard await lightNode.peerManager.dialPeer(bridgeNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec)
    await sleepAsync(100.milliseconds)
    await destNode.connectToNodes(@[bridgeNode.peerInfo.toRemotePeerInfo()])

    ## Given
    let message = fakeWakuMessage()

    var completionFutRelay = newFuture[bool]()
    proc relayHandler(pubsubTopic: PubsubTopic, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data).get()
      check:
        pubsubTopic == DefaultPubsubTopic
        msg == message
      completionFutRelay.complete(true)
    destNode.subscribe(DefaultPubsubTopic, relayHandler)

    # Wait for subscription to take effect
    await sleepAsync(100.millis)

    ## When
    await lightNode.lightpushPublish(DefaultPubsubTopic, message)

    ## Then
    check await completionFutRelay.withTimeout(5.seconds)

    ## Cleanup
    await allFutures(lightNode.stop(), bridgeNode.stop(), destNode.stop())
  