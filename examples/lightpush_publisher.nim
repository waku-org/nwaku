## Example showing how a resource restricted client may
## use lightpush to publish messages without relay

import
  chronicles,
  chronos,
  stew/byteutils,
  stew/results
import
  ../../../waku/common/logging,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_core,
  ../../../waku/waku_lightpush/client

const
  LightpushPeer = "/ip4/134.209.139.210/tcp/30303/p2p/16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ" # node-01.do-ams3.wakuv2.test.statusim.net on wakuv2.test
  LightpushPubsubTopic = PubsubTopic("/waku/2/default-waku/proto")
  LightpushContentTopic = ContentTopic("/examples/1/light-pubsub-example/proto")

proc publishMessages(wlc: WakuLightpushClient,
                     lightpushPeer: RemotePeerInfo,
                     lightpushPubsubTopic: PubsubTopic,
                     lightpushContentTopic: ContentTopic) {.async.} =
  while true:
    let text = "hi there i'm a lightpush publisher"
    let message = WakuMessage(payload: toBytes(text),               # content of the message
                              contentTopic: lightpushContentTopic,  # content topic to publish to
                              ephemeral: true,                      # tell store nodes to not store it
                              timestamp: getNowInNanosecondTime())  # current timestamp

    let wlpRes = await wlc.publish(lightpushPubsubTopic, message, lightpushPeer)

    if wlpRes.isOk():
      notice "published message using lightpush", message=message
    else:
      notice "failed to publish message using lightpush", err=wlpRes.error()

    await sleepAsync(5000) # Publish every 5 seconds

proc setupAndPublish(rng: ref HmacDrbgContext) =
  let lightpushPeer = parsePeerInfo(LightpushPeer).get()

  setupLogLevel(logging.LogLevel.NOTICE)
  notice "starting lightpush publisher"

  var
    switch = newStandardSwitch()
    pm = PeerManager.new(switch)
    wlc = WakuLightpushClient.new(pm, rng)

  # Start maintaining subscription
  asyncSpawn publishMessages(wlc, lightpushPeer, LightpushPubsubTopic, LightpushContentTopic)

when isMainModule:
  let rng = newRng()
  setupAndPublish(rng)
  runForever()
