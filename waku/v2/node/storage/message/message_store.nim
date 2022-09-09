## This module defines a message store interface. Implementations of
## MessageStore are used by the `WakuStore` protocol to store and 
## retrieve historical messages
{.push raises: [Defect].}

import
  std/options,
  stew/results,
  chronos
import
  ../../../protocol/waku_message,
  ../../../utils/time,
  ../../../utils/pagination


const 
  StoreDefaultCapacity* = 25_000
  StoreDefaultRetentionTime* = chronos.days(30).seconds
  StoreMaxPageSize* = 100.uint64
  StoreMaxTimeVariance* = getNanoSecondTime(20) # 20 seconds maximum allowable sender timestamp "drift" into the future


type
  MessageStoreResult*[T] = Result[T, string]
  
  MessageStorePage* = (seq[WakuMessage], Option[PagingInfo])

  MessageStoreRow* = (Timestamp, WakuMessage, string)

  MessageStore* = ref object of RootObj


# MessageStore interface
method put*(ms: MessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] {.base.} = discard

method getAllMessages*(ms: MessageStore): MessageStoreResult[seq[MessageStoreRow]] {.base.} = discard

method getMessagesByHistoryQuery*(
  ms: MessageStore,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(Index),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = StoreMaxPageSize,
  ascendingOrder = true
): MessageStoreResult[MessageStorePage] {.base.} = discard

method getMessagesCount*(ms: MessageStore): int64 {.base.} = discard
