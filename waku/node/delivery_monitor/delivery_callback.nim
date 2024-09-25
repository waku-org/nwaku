import ../../waku_core

type DeliveryDirection* {.pure.} = enum
  PUBLISHING
  RECEIVING

type DeliverySuccess* {.pure.} = enum
  SUCCESSFUL
  UNSUCCESSFUL

type DeliveryFeedbackCallback* = proc(
  success: DeliverySuccess,
  dir: DeliveryDirection,
  comment: string,
  msgHash: WakuMessageHash,
  msg: WakuMessage,
) {.gcsafe, raises: [].}
