when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options
import 
  ../waku_message


type
  ContentFilter* = object
    contentTopic*: string

  FilterRequest* = object
    contentFilters*: seq[ContentFilter]
    pubsubTopic*: string
    subscribe*: bool

  MessagePush* = object
    messages*: seq[WakuMessage]

  FilterRPC* = object
    requestId*: string
    request*: Option[FilterRequest]
    push*: Option[MessagePush]
