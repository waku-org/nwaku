import chronos

import ../../../waku/[waku_core/message, waku_store, waku_store_legacy]

const
  FUTURE_TIMEOUT* = 1.seconds
  FUTURE_TIMEOUT_MEDIUM* = 5.seconds
  FUTURE_TIMEOUT_LONG* = 10.seconds
  FUTURE_TIMEOUT_SHORT* = 100.milliseconds

proc newPushHandlerFuture*(): Future[(string, WakuMessage)] =
  newFuture[(string, WakuMessage)]()

proc newBoolFuture*(): Future[bool] =
  newFuture[bool]()

proc newHistoryFuture*(): Future[StoreQueryRequest] =
  newFuture[StoreQueryRequest]()

proc newLegacyHistoryFuture*(): Future[waku_store_legacy.HistoryQuery] =
  newFuture[waku_store_legacy.HistoryQuery]()

proc toResult*[T](future: Future[T]): Result[T, string] =
  if future.cancelled():
    return chronos.err("Future timeouted before completing.")
  elif future.finished() and not future.failed():
    return chronos.ok(future.read())
  else:
    return chronos.err("Future finished but failed.")

proc toResult*(future: Future[void]): Result[void, string] =
  if future.cancelled():
    return chronos.err("Future timeouted before completing.")
  elif future.finished() and not future.failed():
    return chronos.ok()
  else:
    return chronos.err("Future finished but failed.")

proc waitForResult*[T](
    future: Future[T], timeout = FUTURE_TIMEOUT
): Future[Result[T, string]] {.async.} =
  discard await future.withTimeout(timeout)
  return future.toResult()
