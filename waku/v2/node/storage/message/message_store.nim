## This module defines a message store interface. Implementations of
## MessageStore are used by the `WakuStore` protocol to store and 
## retrieve historical messages
{.push raises: [Defect].}

import
  std/[options, times],
  stew/results
import
  ../../../protocol/waku_message,
  ../../../utils/time,
  ../../../utils/pagination


type
  MessageStoreResult*[T] = Result[T, string]
  
  MessageStorePage* = (seq[WakuMessage], Option[PagingInfo])

  MessageStoreRow* = (Timestamp, WakuMessage, string)

  MessageStore* = ref object of RootObj


# MessageStore interface
method put*(ms: MessageStore, pubsubTopic: string, message: WakuMessage, digest: MessageDigest, receivedTime: Timestamp): MessageStoreResult[void] {.base.} = discard

method put*(ms: MessageStore, pubsubTopic: string, message: WakuMessage): MessageStoreResult[void] =
  let
    digest = computeDigest(message) 
    receivedTime = getNanosecondTime(getTime().toUnixFloat()) 
  
  ms.put(pubsubTopic, message, digest, receivedTime)


method getAllMessages*(ms: MessageStore): MessageStoreResult[seq[MessageStoreRow]] {.base.} = discard

method getMessagesByHistoryQuery*(
  ms: MessageStore,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(Index),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = MaxPageSize,
  ascendingOrder = true
): MessageStoreResult[MessageStorePage] {.base.} = discard


# Store manipulation

method getMessagesCount*(ms: MessageStore): MessageStoreResult[int64] {.base.} = discard

method getOldestMessageTimestamp*(ms: MessageStore): MessageStoreResult[Timestamp] {.base.} = discard

method getNewestMessageTimestamp*(ms: MessageStore): MessageStoreResult[Timestamp]  {.base.} = discard


method deleteMessagesOlderThanTimestamp*(ms: MessageStore, ts: Timestamp): MessageStoreResult[void] {.base.} = discard

method deleteOldestMessagesNotWithinLimit*(ms: MessageStore, limit: int): MessageStoreResult[void] {.base.} = discard