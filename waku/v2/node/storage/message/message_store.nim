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
  ../../../protocol/waku_store/rpc,
  ../../../utils/time,
  ../../../utils/pagination


const 
  StoreDefaultCapacity* = 25_000
  StoreMaxOverflow* = 1.3
  StoreDefaultRetentionTime* = chronos.days(30).seconds
  StoreMaxPageSize* = 100.uint64
  StoreMaxTimeVariance* = getNanoSecondTime(20) # 20 seconds maximum allowable sender timestamp "drift" into the future


type
  MessageStoreResult*[T] = Result[T, string]
  
  MessageStorePage* = (seq[WakuMessage], Option[PagingInfo])

  MessageStoreRow* = (Timestamp, WakuMessage, string)

  MessageStore* = ref object of RootObj

# TODO: Deprecate the following type
type DataProc* = proc(receiverTimestamp: Timestamp, msg: WakuMessage, pubsubTopic: string) {.closure, raises: [Defect].}


# TODO: Remove after resolving nwaku #1026. Move it back to waku_store_queue.nim
type 
  IndexedWakuMessage* = object
    # TODO may need to rename this object as it holds both the index and the pubsub topic of a waku message
    ## This type is used to encapsulate a WakuMessage and its Index
    msg*: WakuMessage
    index*: Index
    pubsubTopic*: string
    
  QueryFilterMatcher* = proc(indexedWakuMsg: IndexedWakuMessage) : bool {.gcsafe, closure.}


# MessageStore interface
method getMostRecentMessageTimestamp*(db: MessageStore): MessageStoreResult[Timestamp] {.base.} = discard

method getOldestMessageTimestamp*(db: MessageStore): MessageStoreResult[Timestamp] {.base.} = discard

method put*(db: MessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] {.base.} = discard


# TODO: Deprecate the following methods after after #1026
method getAll*(db: MessageStore, onData: DataProc): MessageStoreResult[bool] {.base.} = discard
method getPage*(db: MessageStore, pred: QueryFilterMatcher, pagingInfo: PagingInfo): MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] {.base.} = discard
method getPage*(db: MessageStore, pagingInfo: PagingInfo): MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] {.base.} = discard


# TODO: Move to sqlite store
method getAllMessages(db: MessageStore): MessageStoreResult[seq[MessageStoreRow]] {.base.} = discard

method getMessagesByHistoryQuery*(
  db: MessageStore,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(Index),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = StoreMaxPageSize,
  ascendingOrder = true
): MessageStoreResult[MessageStorePage] {.base.} = discard
