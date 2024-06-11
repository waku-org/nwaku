## Example showing how a resource restricted client may
## subscribe to messages without relay

import
  std/options,
  system/ansi_c,
  chronicles,
  chronos,
  chronos/timer as chtimer,
  stew/byteutils,
  stew/results,
  serialization,
  json_serialization as js,
  times
import
  ../../../waku/common/logging,
  ../../../waku/node/peer_manager,
  ../../../waku/waku_node,
  ../../../waku/waku_core,
  ../../../waku/waku_filter_v2/client,
  ./tester_config,
  ./tester_message,
  ./statistics

proc unsubscribe(
    wakuNode: WakuNode,
    filterPeer: RemotePeerInfo,
    filterPubsubTopic: PubsubTopic,
    filterContentTopic: ContentTopic,
) {.async.} =
  notice "unsubscribing from filter"
  let unsubscribeRes = await wakuNode.wakuFilterClient.unsubscribe(
    filterPeer, filterPubsubTopic, @[filterContentTopic]
  )
  if unsubscribeRes.isErr:
    notice "unsubscribe request failed", err = unsubscribeRes.error
  else:
    notice "unsubscribe request successful"

proc maintainSubscription(
    wakuNode: WakuNode,
    filterPeer: RemotePeerInfo,
    filterPubsubTopic: PubsubTopic,
    filterContentTopic: ContentTopic,
) {.async.} =
  while true:
    trace "maintaining subscription"
    # First use filter-ping to check if we have an active subscription
    let pingRes = await wakuNode.wakuFilterClient.ping(filterPeer)
    if pingRes.isErr():
      # No subscription found. Let's subscribe.
      trace "no subscription found. Sending subscribe request"

      let subscribeRes = await wakuNode.filterSubscribe(
        some(filterPubsubTopic), filterContentTopic, filterPeer
      )

      if subscribeRes.isErr():
        trace "subscribe request failed. Quitting.", err = subscribeRes.error
        break
      else:
        trace "subscribe request successful."
    else:
      trace "subscription found."

    await sleepAsync(chtimer.seconds(60)) # Subscription maintenance interval

proc setupAndSubscribe*(wakuNode: WakuNode, conf: LiteProtocolTesterConf) =
  if isNil(wakuNode.wakuFilterClient):
    error "WakuFilterClient not initialized"
    return

  info "Start receiving messages to service node using lightpush",
    serviceNode = conf.serviceNode

  var stats: PerPeerStatistics

  let remotePeer = parsePeerInfo(conf.serviceNode).valueOr:
    error "Couldn't parse the peer info properly", error = error
    return

  let pushHandler = proc(pubsubTopic: PubsubTopic, message: WakuMessage) {.async.} =
    let payloadStr = string.fromBytes(message.payload)
    let testerMessage = js.Json.decode(payloadStr, ProtocolTesterMessage)

    stats.addMessage(testerMessage.sender, testerMessage)

    trace "message received",
      index = testerMessage.index,
      count = testerMessage.count,
      startedAt = $testerMessage.startedAt,
      sinceStart = $testerMessage.sinceStart,
      sincePrev = $testerMessage.sincePrev

  wakuNode.wakuFilterClient.registerPushHandler(pushHandler)

  let interval = millis(20000)
  var printStats: CallbackFunc

  printStats = CallbackFunc(
    proc(udata: pointer) {.gcsafe.} =
      stats.echoStats()

      if stats.checkIfAllMessagesReceived():
        waitFor unsubscribe(
          wakuNode, remotePeer, conf.pubsubTopics[0], conf.contentTopics[0]
        )
        info "All messages received. Exiting."

        ## for gracefull shutdown through signal hooks
        discard c_raise(ansi_c.SIGTERM)
      else:
        discard setTimer(Moment.fromNow(interval), printStats)
  )

  discard setTimer(Moment.fromNow(interval), printStats)

  # Start maintaining subscription
  asyncSpawn maintainSubscription(
    wakuNode, remotePeer, conf.pubsubTopics[0], conf.contentTopics[0]
  )
