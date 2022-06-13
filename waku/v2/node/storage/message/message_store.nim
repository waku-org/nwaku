{.push raises: [Defect].}

import
  std/options,
  stew/results,
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/waku_store_types,
  ../../../utils/time,
  ../../../utils/pagination

## This module defines a message store interface. Implementations of
## MessageStore are used by the `WakuStore` protocol to store and 
## retrieve historical messages

type
  DataProc* = proc(receiverTimestamp: Timestamp, msg: WakuMessage, pubsubTopic: string) {.closure, raises: [Defect].}

  MessageStoreResult*[T] = Result[T, string]

  MessageStore* = ref object of RootObj

# MessageStore interface
method put*(db: MessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] {.base.} = discard
method getAll*(db: MessageStore, onData: DataProc): MessageStoreResult[bool] {.base.} = discard
method getPage*(db: MessageStore, pred: QueryFilterMatcher, pagingInfo: PagingInfo): MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] {.base.} = discard
method getPage*(db: MessageStore, pagingInfo: PagingInfo): MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] {.base.} = discard

