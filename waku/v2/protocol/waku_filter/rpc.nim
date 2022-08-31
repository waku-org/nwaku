import ../waku_message

type
  ContentFilter* = object
    contentTopic*: ContentTopic

  FilterRequest* = object
    contentFilters*: seq[ContentFilter]
    pubSubTopic*: string
    subscribe*: bool

  MessagePush* = object
    messages*: seq[WakuMessage]

  FilterRPC* = object
    requestId*: string
    request*: FilterRequest
    push*: MessagePush
