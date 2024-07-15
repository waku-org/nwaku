## This module reinforces the publish operation with regular store-v3 requests.
##

import std/[tables, sequtils]
import chronos, chronicles, libp2p/utility
import ../../waku_core, ./not_delivered_storage/not_delivered_storage

const DefaultMaxTimeInCache* = chronos.minutes(10)
  ## Messages older than this time will get completely forgotten on publication

const DefaultSendQueryInterval* = chronos.seconds(30)

type DeliveryState = enum
  SENT_NOT_CONFIRMED
  SENT_CONFIRMED

type DeliveryInfo = object
  hash: WakuMessageHash
    ## hash is calculated from the WakuMessage data but we keep is to avoid calculating it again
  wakuMessage: WakuMessage
  state: DeliveryState

type SendMonitor* = ref object
  publishedMessages: Table[string, seq[DeliveryInfo]]
    ## Cache that contains the delivery info per pubsub-topic.
    ## This is needed to make sure the published messages are properly published

  msgStoredCheckerHandle: Future[void] ## handle that allows to stop the async task

  sendQueryInterval: timer.Duration ## time interval between consecutive send retrials
  notDeliveredStorage: NotDeliveredStorage

  storePeers: seq[RemotePeerInfo]

proc new*(
    T: type SendMonitor,
    sendQueryInterval: timer.Duration,
    storePeers: seq[RemotePeerInfo],
): Result[T, string] =
  let notDeliveredStorage = ?NotDeliveredStorage.new()
  return ok(
    SendMonitor(
      sendQueryInterval: sendQueryInterval,
      notDeliveredStorage: notDeliveredStorage,
      storePeers: storePeers,
    )
  )

proc addMessageToDeliveryMonitor*(
    self: SendMonitor, pubsubTopic: string, msgHash: WakuMessageHash, msg: WakuMessage
) =
  ## When publishing a message either through relay or lightpush, we want to add some extra effort
  ## to make sure it is received to one store node. Hence, we keep track of those sent messages.

  let deliveryInfo = DeliveryInfo(
    hash: msgHash, wakuMessage: msg, state: DeliveryState.SENT_NOT_CONFIRMED
  )
  self.publishedMessages.withValue(pubsubTopic, mySeq):
    mySeq[].add(deliveryInfo)
  do:
    self.publishedMessages[pubsubTopic] = newSeq[DeliveryInfo]()
    self.publishedMessages[pubsubTopic].add(deliveryInfo)

proc checkIfMessagesStored(self: SendMonitor) {.async.} =
  ## Continuously monitors that the sent messages have been received by a store node
  while true:
    await sleepAsync(self.sendQueryInterval)

proc confirmMessageDelivered(hashes: seq[WakuMessageHash]) =
  trace "Confirm message delivered", hashes = hashes.mapIt(shortLog(it))
  discard

proc startDeliveryMonitor*(self: SendMonitor) =
  self.msgStoredCheckerHandle = self.checkIfMessagesStored()

proc stopDeliveryMonitor*(self: SendMonitor) =
  self.msgStoredCheckerHandle.cancel()

proc onMessagePublishedRelay*(self: SendMonitor) =
  discard
