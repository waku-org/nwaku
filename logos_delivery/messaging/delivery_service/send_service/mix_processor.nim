import chronicles, chronos, results, brokers/broker_context
import logos_delivery/waku/waku_core, logos_delivery/waku/kernel
import logos_delivery/waku/api/publish
import logos_delivery/waku/waku_mix
import logos_delivery/api/conf/modes

import ./[delivery_task, send_processor]

logScope:
  topics = "send service mix processor"

const MixUnavailableReason* =
  "mix is not mounted or knows fewer than " & $MinMixPoolSize & " usable mix nodes"
  ## The pool counts only members with an address that mix routes.

const MixSelfHopReason* = "this node has no address that mix can use for replies"
  ## An IPv6-only or name-only announcement, or a NAT mapping not yet arrived.

const MixNoExitReason* = "no mix node serves lightpush on the shard of the message"
  ## No pool member serves lightpush on the message's shard.

const MixUnusableGrace* = chronos.seconds(3)
  ## How long after its admission a `Required` task waits for a mounted mix that
  ## cannot attempt it. Retries come `RetryInterval` apart.

type
  MixUnusable* {.pure.} = enum
    ## Why mix cannot attempt a task now.
    None
    Unavailable
    SelfHop
    NoExit

  MixSendProcessor* = ref object of BaseSendProcessor
    kernel: Kernel
    fallbackAllowed: bool
    mixWindow: timer.Duration
    fellBackReason: MixUnusable
      ## Why the last task went to the plain path; `None` once mix can attempt
      ## a task again. INFO logs each change.

proc reason*(unusable: MixUnusable): string =
  ## The text written to `errorDesc` and the log lines.
  case unusable
  of MixUnusable.None: ""
  of MixUnusable.Unavailable: MixUnavailableReason
  of MixUnusable.SelfHop: MixSelfHopReason
  of MixUnusable.NoExit: MixNoExitReason

proc fellBackFor*(self: MixSendProcessor): MixUnusable =
  ## Why the last task went to the plain path, or `None` once mix can attempt a
  ## task again.
  self.fellBackReason

proc new*(
    T: typedesc[MixSendProcessor],
    kernel: Kernel,
    brokerCtx: BrokerContext,
    anonymityLevel: AnonymityLevel,
    mixWindow: timer.Duration,
): T =
  return T(
    kernel: kernel,
    brokerCtx: brokerCtx,
    fallbackAllowed: anonymityLevel == AnonymityLevel.Preferred,
    mixWindow: mixWindow,
  )

method isValidProcessor*(self: MixSendProcessor, task: DeliveryTask): bool {.gcsafe.} =
  return true

proc mixWindowElapsed(self: MixSendProcessor, task: DeliveryTask): bool =
  ## True once `task` has spent its whole mix window, which bounds failed mix
  ## attempts at either level.
  return task.admissionAge() > self.mixWindow

proc mixUnusable(self: MixSendProcessor, task: DeliveryTask): MixUnusable =
  ## Why mix cannot attempt `task` now, with no network call. It splits
  ## `mixReady()` into the self hop and the pool, then checks the exit with
  ## `selectMixLightpushPeer`, as `lightpushPublishToAny(mixify = true)` does.
  if not self.kernel.mixReady():
    if self.kernel.mixMounted() and not self.kernel.mixSelfHopUsable():
      return MixUnusable.SelfHop
    return MixUnusable.Unavailable
  if self.kernel.selectMixLightpushPeer(task.pubsubTopic).isNone():
    return MixUnusable.NoExit
  return MixUnusable.None

proc decideWithoutMix(
    self: MixSendProcessor, task: DeliveryTask, unusable: MixUnusable
) =
  ## Hands a `Preferred` task to the plain path at once. Fails a `Required` task
  ## with the reason, once its admission is older than `MixUnusableGrace` while
  ## mix is mounted.
  if not self.fallbackAllowed:
    if self.kernel.mixMounted() and task.admissionAge() <= MixUnusableGrace:
      task.errorDesc = unusable.reason()
      task.state = DeliveryState.NextRoundRetry
      return
    debug "Mix cannot attempt the task, and the Required anonymity level allows no send without mix",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      reason = unusable.reason()
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = unusable.reason()
    return

  if self.fellBackReason != unusable:
    self.fellBackReason = unusable
    info "Mix cannot carry messages, sending them over the plain path instead",
      reason = unusable.reason()
  debug "Mix cannot attempt the task, handing it to the plain send path",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    reason = unusable.reason()
  task.errorDesc = "" # the plain path reports its own outcome
  task.state = DeliveryState.FallbackRetry

method sendImpl*(self: MixSendProcessor, task: DeliveryTask): Future[void] {.async.} =
  # Check the reasons before the window, so that the hand-over of a task that
  # mix cannot attempt logs its reason at INFO.
  let unusable = self.mixUnusable(task)
  if unusable != MixUnusable.None:
    self.decideWithoutMix(task, unusable)
    return

  if self.fellBackReason != MixUnusable.None:
    self.fellBackReason = MixUnusable.None
    info "Mix can carry messages again"

  if self.fallbackAllowed and self.mixWindowElapsed(task):
    debug "Mix window elapsed, handing the task to the plain send path",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      admissionAge = task.admissionAge()
    task.errorDesc = ""
    task.state = DeliveryState.FallbackRetry
    return

  # Mark before the attempt: the exit publishes before it replies, so a message
  # whose reply is lost is still on the network. From here on, the send service
  # logs no hash for this task at INFO or ERROR.
  task.anonymized = true

  task.errorDesc = "" # the attempt reports its own outcome
  task.tryCount.inc()
  debug "Trying message delivery via Mix",
    requestId = task.requestId,
    msgHash = task.msgHash.to0xHex(),
    tryCount = task.tryCount

  let numLightpushServers = (
    await self.kernel.lightpushPublishToAny(task.pubsubTopic, task.msg, mixify = true)
  ).valueOr:
    debug "MixSendProcessor.sendImpl failed", error = error.desc.get($error.code)

    if error.isRlnRejection():
      task.parkForRlnProofRefresh(self.kernel, error.desc.get($error.code))
      return

    case error.code
    of LightPushErrorCode.NO_PEERS_TO_RELAY, LightPushErrorCode.TOO_MANY_REQUESTS,
        LightPushErrorCode.OUT_OF_RLN_PROOF, LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        LightPushErrorCode.INTERNAL_SERVER_ERROR:
      task.state = DeliveryState.NextRoundRetry
    else:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = error.desc.get($error.code)
    return

  if numLightpushServers > 0:
    debug "Message propagated via Mix",
      requestId = task.requestId, msgHash = task.msgHash.to0xHex()
    task.state = DeliveryState.SuccessfullyPropagated
    task.propagatedAnonymously = true
    if task.firstPropagatedTime.isNone():
      task.firstPropagatedTime = Opt.some(Moment.now())
  else:
    debug "Mix publish returned zero peers, the task waits for a retry",
      requestId = task.requestId
    task.state = DeliveryState.NextRoundRetry

  return
