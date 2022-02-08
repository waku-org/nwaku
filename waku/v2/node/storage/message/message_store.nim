{.push raises: [Defect].}

import
  std/options,
  stew/results,
  ../../../protocol/waku_message,
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
method getAll*(db: MessageStore, onData: DataProc, limit = none(int)): MessageStoreResult[bool] {.base.} = discard

