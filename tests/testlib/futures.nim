import
  chronos

import 
  ../../../waku/[
    waku_core/message,
    waku_store
  ]


let FUTURE_TIMEOUT* = 1.seconds

proc newPushHandlerFuture*(): Future[(string, WakuMessage)] =
    newFuture[(string, WakuMessage)]()

proc newBoolFuture*(): Future[bool] =
    newFuture[bool]()

proc newHistoryFuture*(): Future[HistoryQuery] =
    newFuture[HistoryQuery]()


proc toResult*[T](future: Future[T]): Result[T, string] =
  if future.finished():
    return chronos.ok(future.read())
  else:
    return chronos.err("Future not finished.")

proc toResult*(future: Future[void]): Result[void, string] =
  if future.finished():
    return chronos.ok()
  else:
    return chronos.err("Future not finished.")

proc waitForResult*[T](future: Future[T], timeout = FUTURE_TIMEOUT): Future[Result[T, string]] {.async.} =
  discard await future.withTimeout(timeout)
  return future.toResult()
