import chronos

import ../../../waku/[waku_core/message, waku_store]

const
  FUTURE_TIMEOUT* = 1.seconds
  FUTURE_TIMEOUT_LONG* = 10.seconds

proc newPushHandlerFuture*(): Future[(string, WakuMessage)] =
  newFuture[(string, WakuMessage)]()

proc newBoolFuture*(): Future[bool] =
  newFuture[bool]()

proc newHistoryFuture*(): Future[HistoryQuery] =
  newFuture[HistoryQuery]()
