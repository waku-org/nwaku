## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##

import std/[tables, sequtils, sets, options]
import chronos, chronicles, libp2p/utility
import
  ../../waku_core,
  ./delivery_callback,
  ./subscriptions_observer,
  ../../waku_store/[client, common],
  ../../waku_filter_v2/client,
  ../../waku_core/topics

const StoreCheckPeriod = chronos.minutes(5) ## How often to perform store queries

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const PruneOldMsgsPeriod = chronos.minutes(1)

const DelayExtra* = chronos.seconds(5)
  ## Additional security time to overlap the missing messages queries

type TupleHashAndMsg = tuple[hash: WakuMessageHash, msg: WakuMessage]

type RecvMessage = object
  msgHash: WakuMessageHash
  rxTime: Timestamp
    ## timestamp of the rx message. We will not keep the rx messages forever

type RecvMonitor* = ref object of SubscriptionObserver
  topicsInterest: Table[PubsubTopic, seq[ContentTopic]]
    ## Tracks message verification requests and when was the last time a
    ## pubsub topic was verified for missing messages
    ## The key contains pubsub-topics

  storeClient: WakuStoreClient
  deliveryCb: DeliveryFeedbackCallback

  recentReceivedMsgs: seq[RecvMessage]

  msgCheckerHandler: Future[void] ## allows to stop the msgChecker async task
  msgPrunerHandler: Future[void] ## removes too old messages

  startTimeToCheck: Timestamp
  endTimeToCheck: Timestamp

proc getMissingMsgsFromStore(
    self: RecvMonitor, msgHashes: seq[WakuMessageHash]
): Future[Result[seq[TupleHashAndMsg], string]] {.async.} =
  let storeResp: StoreQueryResponse = (
    await self.storeClient.queryToAny(
      StoreQueryRequest(includeData: true, messageHashes: msgHashes)
    )
  ).valueOr:
    return err("getMissingMsgsFromStore: " & $error)

  let otherwiseMsg = WakuMessage()
    ## message to be returned if the Option message is none
  return ok(
    storeResp.messages.mapIt((hash: it.messageHash, msg: it.message.get(otherwiseMsg)))
  )

proc performDeliveryFeedback(
    self: RecvMonitor,
    success: DeliverySuccess,
    dir: DeliveryDirection,
    comment: string,
    msgHash: WakuMessageHash,
    msg: WakuMessage,
) {.gcsafe, raises: [].} =
  ## This procs allows to bring delivery feedback to the API client
  ## It requires a 'deliveryCb' to be registered beforehand.
  if self.deliveryCb.isNil():
    error "deliveryCb is nil in performDeliveryFeedback",
      success, dir, comment, msg_hash
    return

  debug "recv monitor performDeliveryFeedback",
    success, dir, comment, msg_hash = shortLog(msgHash)
  self.deliveryCb(success, dir, comment, msgHash, msg)

proc msgChecker(self: RecvMonitor) {.async.} =
  ## Continuously checks if a message has been received
  while true:
    await sleepAsync(StoreCheckPeriod)

    self.endTimeToCheck = getNowInNanosecondTime()

    var msgHashesInStore = newSeq[WakuMessageHash](0)
    for pubsubTopic, cTopics in self.topicsInterest.pairs:
      let storeResp: StoreQueryResponse = (
        await self.storeClient.queryToAny(
          StoreQueryRequest(
            includeData: false,
            pubsubTopic: some(PubsubTopic(pubsubTopic)),
            contentTopics: cTopics,
            startTime: some(self.startTimeToCheck - DelayExtra.nanos),
            endTime: some(self.endTimeToCheck + DelayExtra.nanos),
          )
        )
      ).valueOr:
        error "msgChecker failed to get remote msgHashes",
          pubsubTopic, cTopics, error = $error
        continue

      msgHashesInStore.add(storeResp.messages.mapIt(it.messageHash))

    ## compare the msgHashes seen from the store vs the ones received directly
    let rxMsgHashes = self.recentReceivedMsgs.mapIt(it.msgHash)
    let missedHashes: seq[WakuMessageHash] =
      msgHashesInStore.filterIt(not rxMsgHashes.contains(it))

    ## Now retrieve the missed WakuMessages
    let missingMsgsRet = await self.getMissingMsgsFromStore(missedHashes)
    if missingMsgsRet.isOk():
      ## Give feedback so that the api client can perfom any action with the missed messages
      for msgTuple in missingMsgsRet.get():
        self.performDeliveryFeedback(
          DeliverySuccess.UNSUCCESSFUL, RECEIVING, "Missed message", msgTuple.hash,
          msgTuple.msg,
        )
    else:
      error "failed to retrieve missing messages: ", error = $missingMsgsRet.error

    ## update next check times
    self.startTimeToCheck = self.endTimeToCheck

method onSubscribe(
    self: RecvMonitor, pubsubTopic: string, contentTopics: seq[string]
) {.gcsafe, raises: [].} =
  debug "onSubscribe", pubsubTopic, contentTopics
  self.topicsInterest.withValue(pubsubTopic, contentTopicsOfInterest):
    contentTopicsOfInterest[].add(contentTopics)
  do:
    self.topicsInterest[pubsubTopic] = contentTopics

method onUnsubscribe(
    self: RecvMonitor, pubsubTopic: string, contentTopics: seq[string]
) {.gcsafe, raises: [].} =
  debug "onUnsubscribe", pubsubTopic, contentTopics

  self.topicsInterest.withValue(pubsubTopic, contentTopicsOfInterest):
    let remainingCTopics =
      contentTopicsOfInterest[].filterIt(not contentTopics.contains(it))
    contentTopicsOfInterest[] = remainingCTopics

    if remainingCTopics.len == 0:
      self.topicsInterest.del(pubsubTopic)
  do:
    error "onUnsubscribe unsubscribing from wrong topic", pubsubTopic, contentTopics

proc new*(
    T: type RecvMonitor,
    storeClient: WakuStoreClient,
    wakuFilterClient: WakuFilterClient,
): T =
  ## The storeClient will help to acquire any possible missed messages

  let now = getNowInNanosecondTime()
  var recvMonitor = RecvMonitor(storeClient: storeClient, startTimeToCheck: now)

  if not wakuFilterClient.isNil():
    wakuFilterClient.addSubscrObserver(recvMonitor)

    let filterPushHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ) {.async, closure.} =
      ## Captures all the messages recived through filter

      let msgHash = computeMessageHash(pubSubTopic, message)
      let rxMsg = RecvMessage(msgHash: msgHash, rxTime: message.timestamp)
      recvMonitor.recentReceivedMsgs.add(rxMsg)

    wakuFilterClient.registerPushHandler(filterPushHandler)

  return recvMonitor

proc loopPruneOldMessages(self: RecvMonitor) {.async.} =
  while true:
    let oldestAllowedTime = getNowInNanosecondTime() - MaxMessageLife.nanos
    self.recentReceivedMsgs.keepItIf(it.rxTime > oldestAllowedTime)
    await sleepAsync(PruneOldMsgsPeriod)

proc startRecvMonitor*(self: RecvMonitor) =
  self.msgCheckerHandler = self.msgChecker()
  self.msgPrunerHandler = self.loopPruneOldMessages()

proc stopRecvMonitor*(self: RecvMonitor) {.async.} =
  if not self.msgCheckerHandler.isNil():
    await self.msgCheckerHandler.cancelAndWait()
  if not self.msgPrunerHandler.isNil():
    await self.msgPrunerHandler.cancelAndWait()

proc setDeliveryCallback*(self: RecvMonitor, deliveryCb: DeliveryFeedbackCallback) =
  self.deliveryCb = deliveryCb
