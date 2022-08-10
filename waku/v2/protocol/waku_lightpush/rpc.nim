{.push raises: [Defec].}

import
  ../waku_message

type
  PushRequest* = object
    pubSubTopic*: string
    message*: WakuMessage

  PushResponse* = object
    isSuccess*: bool
    info*: string

  PushRPC* = object
    requestId*: string
    request*: PushRequest
    response*: PushResponse