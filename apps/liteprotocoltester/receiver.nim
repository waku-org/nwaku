## Example showing how a resource restricted client may
## subscribe to messages without relay

import
  system/ansi_c,
  chronicles,
  chronos,
  chronos/timer as chtimer,
  stew/byteutils,
  results,
  serialization,
  json_serialization as js

import
  logos_delivery/kernel/[
    common/logging,
    peer_manager/peer_manager,
    kernel,
    api/filter,
    common/topics/content_topic,
    common/topics/pubsub_topic,
    common/enr/sharding,
    common/message,
    common/peers,
    common/codecs,
    protocols/filter/client,
    protocols/filter/common,
  ],
  ./tester_config,
  ./tester_message,
  ./statistics,
  ./service_peer_management,
  ./lpt_metrics
var actualFilterPeer {.threadvar.}: RemotePeerInfo

proc unsubscribe(
    kernel: Kernel, filterPubsubTopic: PubsubTopic, filterContentTopic: ContentTopic
) {.async.} =
  notice "unsubscribing from filter"
  let unsubscribeRes = await kernel.protocols.filterClient.unsubscribe(
    actualFilterPeer, filterPubsubTopic, @[filterContentTopic]
  )
  if unsubscribeRes.isErr:
    notice "unsubscribe request failed", err = unsubscribeRes.error
  else:
    notice "unsubscribe request successful"

proc maintainSubscription(
    kernel: Kernel,
    filterPubsubTopic: PubsubTopic,
    filterContentTopic: ContentTopic,
    preventPeerSwitch: bool,
) {.async.} =
  const maxFailedSubscribes = 3
  const maxFailedServiceNodeSwitches = 10
  var noFailedSubscribes = 0
  var noFailedServiceNodeSwitches = 0
  var isFirstPingOnNewPeer = true
  const RetryWaitMs = 2.seconds # Quick retry interval
  const SubscriptionMaintenanceMs = 30.seconds # Subscription maintenance interval
  while true:
    info "maintaining subscription at", peer = constructMultiaddrStr(actualFilterPeer)
    # First use filter-ping to check if we have an active subscription
    let pingErr = (await kernel.protocols.filterClient.ping(actualFilterPeer)).errorOr:
      await sleepAsync(SubscriptionMaintenanceMs)
      info "subscription is live."
      continue

    if isFirstPingOnNewPeer == false:
      # Very first ping expected to fail as we have not yet subscribed at all
      logos_delivery_lpt_receiver_lost_subscription_count.inc()
    isFirstPingOnNewPeer = false
    # No subscription found. Let's subscribe.
    error "ping failed.", error = pingErr
    trace "no subscription found. Sending subscribe request"

    let subscribeErr = (
      await kernel.filterSubscribe(
        Opt.some(filterPubsubTopic), filterContentTopic, actualFilterPeer
      )
    ).errorOr:
      await sleepAsync(SubscriptionMaintenanceMs)
      if noFailedSubscribes > 0:
        noFailedSubscribes -= 1
      notice "subscribe request successful."
      continue

    noFailedSubscribes += 1
    logos_delivery_lpt_service_peer_failure_count.inc(
      labelValues = ["receiver", actualFilterPeer.getAgent()]
    )
    error "Subscribe request failed.",
      err = subscribeErr, peer = actualFilterPeer, failCount = noFailedSubscribes

    # TODO: disconnet from failed actualFilterPeer
    # asyncSpawn(kernel.peerManager.switch.disconnect(p))
    # wakunode.peerManager.peerStore.delete(actualFilterPeer)

    if noFailedSubscribes < maxFailedSubscribes:
      await sleepAsync(RetryWaitMs) # Wait a bit before retrying
    elif not preventPeerSwitch:
      # try again with new peer without delay
      actualFilterPeer = selectRandomServicePeer(
        kernel.peerManager, Opt.some(actualFilterPeer), WakuFilterSubscribeCodec
      ).valueOr:
        error "Failed to find new service peer. Exiting."
        noFailedServiceNodeSwitches += 1
        break

      info "Found new peer for codec",
        codec = filterPubsubTopic, peer = constructMultiaddrStr(actualFilterPeer)

      noFailedSubscribes = 0
      logos_delivery_lpt_change_service_peer_count.inc(labelValues = ["receiver"])
      isFirstPingOnNewPeer = true
    else:
      await sleepAsync(SubscriptionMaintenanceMs)

proc setupAndListen*(
    kernel: Kernel, conf: LiteProtocolTesterConf, servicePeer: RemotePeerInfo
) =
  if isNil(kernel.protocols.filterClient):
    # if we have not yet initialized lightpush client, then do it as the only way we can get here is
    # by having a service peer discovered.
    waitFor kernel.mountFilterClient()

  info "Start receiving messages to service node using filter",
    servicePeer = servicePeer

  var stats: PerPeerStatistics
  actualFilterPeer = servicePeer

  let pushHandler = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): Future[void] {.async, closure.} =
    let payloadStr = string.fromBytes(message.payload)
    let testerMessage = js.Json.decode(payloadStr, ProtocolTesterMessage)
    let msgHash = computeMessageHash(pubsubTopic, message).to0xHex

    stats.addMessage(testerMessage.sender, testerMessage, msgHash)

    notice "message received",
      index = testerMessage.index,
      count = testerMessage.count,
      startedAt = $testerMessage.startedAt,
      sinceStart = $testerMessage.sinceStart,
      sincePrev = $testerMessage.sincePrev,
      size = $testerMessage.size,
      pubsubTopic = pubsubTopic,
      hash = msgHash

  kernel.protocols.filterClient.registerPushHandler(pushHandler)

  let interval = millis(20000)
  var printStats: CallbackFunc

  # calculate max wait after the last known message arrived before exiting
  # 20% of expected messages times the expected interval but capped to 10min
  let maxWaitForLastMessage: Duration =
    min(conf.messageInterval.milliseconds * (conf.numMessages div 5), 10.minutes)

  printStats = CallbackFunc(
    proc(udata: pointer) {.gcsafe.} =
      stats.echoStats()

      if conf.numMessages > 0 and
          waitFor stats.checkIfAllMessagesReceived(maxWaitForLastMessage):
        waitFor unsubscribe(kernel, conf.getPubsubTopic(), conf.contentTopics[0])
        info "All messages received. Exiting."

        ## for gracefull shutdown through signal hooks
        discard c_raise(ansi_c.SIGTERM)
      else:
        discard setTimer(Moment.fromNow(interval), printStats)
  )

  discard setTimer(Moment.fromNow(interval), printStats)

  # Start maintaining subscription
  asyncSpawn maintainSubscription(
    kernel, conf.getPubsubTopic(), conf.contentTopics[0], conf.fixedServicePeer
  )
