import results, chronos, chronicles
import brokers/broker_context
import
  logos_delivery/kernel/[topics/pubsub_topic, protocols/message],
  logos_delivery/kernel/protocols/lightpush/[common, rpc]
import logos_delivery/kernel/kernel_lifecycle, logos_delivery/kernel/api/publish
import logos_delivery/kernel/requests/health_requests
import logos_delivery/api/types
import ./[delivery_task, send_processor]

logScope:
  topics = "send service relay processor"

type RelaySendProcessor* = ref object of BaseSendProcessor
  kernel: Kernel
  publishProc: PushMessageHandler
  fallbackStateToSet: DeliveryState

proc new*(
    T: typedesc[RelaySendProcessor],
    lightpushAvailable: bool,
    publishProc: PushMessageHandler,
    kernel: Kernel,
    brokerCtx: BrokerContext,
): RelaySendProcessor =
  let fallbackStateToSet =
    if lightpushAvailable:
      DeliveryState.FallbackRetry
    else:
      DeliveryState.FailedToDeliver

  return RelaySendProcessor(
    kernel: kernel,
    publishProc: publishProc,
    fallbackStateToSet: fallbackStateToSet,
    brokerCtx: brokerCtx,
  )

proc isTopicHealthy(self: RelaySendProcessor, topic: PubsubTopic): bool {.gcsafe.} =
  let healthReport = RequestShardTopicsHealth.request(self.brokerCtx, @[topic]).valueOr:
    debug "isTopicHealthy: failed to get health report", topic = topic, error = error
    return false

  if healthReport.topicHealth.len() < 1:
    debug "isTopicHealthy: no topic health entries", topic = topic
    return false
  let health = healthReport.topicHealth[0].health
  debug "isTopicHealthy: topic health is ", topic = topic, health = health
  return health == MINIMALLY_HEALTHY or health == SUFFICIENTLY_HEALTHY

method isValidProcessor*(
    self: RelaySendProcessor, task: DeliveryTask
): bool {.gcsafe.} =
  # Topic health query is not reliable enough after a fresh subscribe...
  # return self.isTopicHealthy(task.pubsubTopic)
  return true

method sendImpl*(self: RelaySendProcessor, task: DeliveryTask) {.async.} =
  task.tryCount.inc()
  debug "Trying message delivery via Relay",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    tryCount = task.tryCount

  let noOfPublishedPeers = (await self.publishProc(task.pubsubTopic, task.msg)).valueOr:
    let errorMessage = error.desc.get($error.code)
    debug "Failed to publish message with relay",
      request = task.requestId, msgHash = task.msgHash.to0xHex(), error = errorMessage

    if error.isRlnRejection():
      task.parkForRlnProofRefresh(self.kernel, errorMessage)
      return

    if error.code != LightPushErrorCode.NO_PEERS_TO_RELAY:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = errorMessage
    else:
      task.state = self.fallbackStateToSet
    return

  if noOfPublishedPeers > 0:
    debug "Message propagated via Relay",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      noOfPeers = noOfPublishedPeers
    task.state = DeliveryState.SuccessfullyPropagated
    if task.firstPropagatedTime.isNone():
      task.firstPropagatedTime = Opt.some(Moment.now())
  else:
    # It shall not happen, but still covering it
    task.state = self.fallbackStateToSet
