import
  chronicles,
  chronos

import ../../../waku/waku_core/message

proc newPushHandlerFuture*(): Future[(string, WakuMessage)] =
    newFuture[(string, WakuMessage)]()

proc newBoolFuture*(): Future[bool] =
    newFuture[bool]()
