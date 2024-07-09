## Example showing how a resource restricted client may
## subscribe to messages without relay

import chronicles, chronos, stew/byteutils, results
import waku/[common/logging, node/peer_manager, waku_core, waku_filter_v2/client]

const
  FilterPeer =
    "/ip4/34.16.1.67/tcp/30303/p2p/16Uiu2HAmDCp8XJ9z1ev18zuv8NHekAsjNyezAvmMfFEJkiharitG"
    # node-01.gc-us-central1-a.waku.test.statusim.net on waku.test
  FilterPubsubTopic = PubsubTopic("/waku/2/default-waku/proto")
  FilterContentTopic = ContentTopic("/examples/1/light-pubsub-example/proto")

proc unsubscribe(
    wfc: WakuFilterClient,
    filterPeer: RemotePeerInfo,
    filterPubsubTopic: PubsubTopic,
    filterContentTopic: ContentTopic,
) {.async.} =
  notice "unsubscribing from filter"
  let unsubscribeRes =
    await wfc.unsubscribe(filterPeer, filterPubsubTopic, @[filterContentTopic])
  if unsubscribeRes.isErr:
    notice "unsubscribe request failed", err = unsubscribeRes.error
  else:
    notice "unsubscribe request successful"

proc messagePushHandler(
    pubsubTopic: PubsubTopic, message: WakuMessage
) {.async, gcsafe.} =
  let payloadStr = string.fromBytes(message.payload)
  notice "message received",
    payload = payloadStr,
    pubsubTopic = pubsubTopic,
    contentTopic = message.contentTopic,
    timestamp = message.timestamp

proc maintainSubscription(
    wfc: WakuFilterClient,
    filterPeer: RemotePeerInfo,
    filterPubsubTopic: PubsubTopic,
    filterContentTopic: ContentTopic,
) {.async.} =
  while true:
    notice "maintaining subscription"
    # First use filter-ping to check if we have an active subscription
    let pingRes = await wfc.ping(filterPeer)
    if pingRes.isErr():
      # No subscription found. Let's subscribe.
      notice "no subscription found. Sending subscribe request"

      let subscribeRes =
        await wfc.subscribe(filterPeer, filterPubsubTopic, @[filterContentTopic])

      if subscribeRes.isErr():
        notice "subscribe request failed. Quitting.", err = subscribeRes.error
        break
      else:
        notice "subscribe request successful."
    else:
      notice "subscription found."

    await sleepAsync(60.seconds) # Subscription maintenance interval

proc setupAndSubscribe(rng: ref HmacDrbgContext) =
  let filterPeer = parsePeerInfo(FilterPeer).get()

  setupLog(logging.LogLevel.NOTICE, logging.LogFormat.TEXT)
  notice "starting filter subscriber"

  var
    switch = newStandardSwitch()
    pm = PeerManager.new(switch)
    wfc = WakuFilterClient.new(pm, rng)

  # Mount filter client protocol
  switch.mount(wfc)

  wfc.registerPushHandler(messagePushHandler)

  # Start maintaining subscription
  asyncSpawn maintainSubscription(
    wfc, filterPeer, FilterPubsubTopic, FilterContentTopic
  )

when isMainModule:
  let rng = newRng()
  setupAndSubscribe(rng)
  runForever()
