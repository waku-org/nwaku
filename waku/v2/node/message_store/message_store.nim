import
  stew/results,
  ../../protocol/waku_message,
  ../../utils/pagination

## This module defines a message store interface. Implementations of
## MessageStore are used by the `WakuStore` protocol to store and re-
## trieve historical messages

type
  DataProc* = proc(timestamp: uint64, msg: WakuMessage) {.closure.}

  MessageStoreResult*[T] = Result[T, string]

  MessageStore* = ref object of RootObj

# MessageStore interface
method put*(db: MessageStore, cursor: Index, message: WakuMessage): MessageStoreResult[void] {.base.} = discard
method getAll*(db: MessageStore, onData: DataProc): MessageStoreResult[bool] {.base.} = discard
