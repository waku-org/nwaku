{.push raises: [Defect].}

import
  stew/results,
  ../../../protocol/waku_message,
  ../../../utils/pagination

## This module defines a message store interface. Implementations of
## MessageStore are used by the `WakuStore` protocol to store and 
## retrieve historical messages

type
  DataProc* = proc(receiverTimestamp: float64, msg: WakuMessage, pubsubTopic: string) {.closure, raises: [Defect].}

  MessageStoreResult*[T] = Result[T, string]

  MessageStore* = ref object of RootObj

# MessageStore interface
method put*(db: MessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] {.base.} = discard
method getAll*(db: MessageStore, onData: DataProc): MessageStoreResult[bool] {.base.} = discard

