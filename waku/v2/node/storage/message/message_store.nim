## This module defines a message store interface. Implementations of
## MessageStore are used by the `WakuStore` protocol to store and 
## retrieve historical messages
{.push raises: [Defect].}

import
  std/options,
  stew/results,
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/rpc,
  ../../../utils/time,
  ../../../utils/pagination


type
  DataProc* = proc(receiverTimestamp: Timestamp, msg: WakuMessage, pubsubTopic: string) {.closure, raises: [Defect].}

  MessageStoreResult*[T] = Result[T, string]

  MessageStore* = ref object of RootObj


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
method put*(db: MessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] {.base.} = discard
method getAll*(db: MessageStore, onData: DataProc): MessageStoreResult[bool] {.base.} = discard
method getPage*(db: MessageStore, pred: QueryFilterMatcher, pagingInfo: PagingInfo): MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] {.base.} = discard
method getPage*(db: MessageStore, pagingInfo: PagingInfo): MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] {.base.} = discard

