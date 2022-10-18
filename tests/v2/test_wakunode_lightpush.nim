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
  ../../waku/v2/utils/time,
  ../../waku/v2/node/waku_node

from std/times import getTime, toUnixFloat


const 
  DefaultPubsubTopic = "/waku/2/default-waku/proto"
  DefaultContentTopic = ContentTopic("/waku/2/default-content/proto")

proc now(): Timestamp = 
  getNanosecondTime(getTime().toUnixFloat())

proc fakeWakuMessage(
  payload = "TEST-PAYLOAD",
  contentTopic = DefaultContentTopic, 
  ts = now()
): WakuMessage = 
  WakuMessage(
    payload: toBytes(payload),
    contentTopic: contentTopic,
    version: 1,
    timestamp: ts
  )


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
    await lightNode.mountLightPush()
    
    discard await lightNode.peerManager.dialPeer(bridgeNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec)
    await sleepAsync(100.milliseconds)
    await destNode.connectToNodes(@[bridgeNode.peerInfo.toRemotePeerInfo()])

    ## Given
    let message = fakeWakuMessage()

    var completionFutRelay = newFuture[bool]()
    proc relayHandler(pubsubTopic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data).get()
      check:
        pubsubTopic == DefaultPubsubTopic
        msg == message
      completionFutRelay.complete(true)
    destNode.subscribe(DefaultPubsubTopic, relayHandler)

    # Wait for subscription to take effect
    await sleepAsync(100.millis)

    ## When
    let lightpushRes = await lightNode.lightpush(DefaultPubsubTopic, message)

    require (await completionFutRelay.withTimeout(5.seconds)) == true
    
    ## Then
    check lightpushRes.isOk()
      
    let response = lightpushRes.get()
    check:
      response.isSuccess == true

    ## Cleanup
    await allFutures(lightNode.stop(), bridgeNode.stop(), destNode.stop())
  