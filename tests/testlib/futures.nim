import
  chronos

import ../../../waku/waku_core/message


let FUTURE_TIMEOUT* = 1.seconds

proc newPushHandlerFuture*(): Future[(string, WakuMessage)] =
    newFuture[(string, WakuMessage)]()

proc newBoolFuture*(): Future[bool] =
    newFuture[bool]()
