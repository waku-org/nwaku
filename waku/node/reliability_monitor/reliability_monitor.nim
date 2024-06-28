## This module is aimed to give an additional layer of certainty in message delivery and reception,
## which is leveraged by the store-v3 protocol.
## Summarizing, we send periodic store-v3 requests for messages that we are interested in,
## and we send an
## On the other hand, this will help to double-check that the
## We consider that a message has been delivered if other store node has received it
##

import std/[tables, sequtils]
import chronos, chronicles, libp2p/utility
import ../../waku_core

type DeliveryState = enum
  SENT_NOT_CONFIRMED
  SENT_CONFIRMED

type DeliveryInfo = object
  hash: WakuMessageHash
    ## hash is calculated from the WakuMessage data but we keep is to avoid calculating it again
  wakuMessage: WakuMessage
  state: DeliveryState

type DeliveryMonitor* = ref object
  publishedMessages: Table[string, seq[DeliveryInfo]]
    ## cache that contains the delivery info per pubsub-topic

  msgStoredCheckerHandle: Future[void] ## handle that allows to stop the async task

const MaxTimeInCache = chronos.minutes(10)
  ## Messages older than this time will get completely forgotten

const MaxHashQueryLength = 100

const HashQueryInterval = chronos.seconds(5)

proc confirmMessageDelivered(hashes: seq[WakuMessageHash]) =
  trace "Confirm message delivered", hashes = hashes.mapIt(shortLog(it))
  discard

proc addMessageToDeliveryMonitor(
    self: DeliveryMonitor, pubsubTopic: string, msg: WakuMessage
) =
  self.publishedMessages.withValue(pubsubTopic)

proc checkIfMessagesStored(self: DeliveryMonitor) {.async.} =
  ## Continuously monitors that the sent messages have been received by a store node
  while true:
    await sleepAsync(HashQueryInterval)

proc startDeliveryMonitor*(self: DeliveryMonitor) =
  self.msgStoredCheckerHandle = self.checkIfMessagesStored()

proc stopDeliveryMonitor*(self: DeliveryMonitor) =
  self.msgStoredCheckerHandle.cancel()
