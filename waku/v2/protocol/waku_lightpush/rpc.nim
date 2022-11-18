when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options
import
  ../waku_message

type
  PushRequest* = object
    pubSubTopic*: string
    message*: WakuMessage

  PushResponse* = object
    isSuccess*: bool
    info*: Option[string]

  PushRPC* = object
    requestId*: string
    request*: Option[PushRequest]
    response*: Option[PushResponse]
