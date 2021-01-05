import
  std/[tables],
  bearssl,
  libp2p/[switch, peerinfo],
  libp2p/protocols/protocol,
  ../waku_message

export waku_message

type
  ContentFilter* = object
    topics*: seq[ContentTopic]

  ContentFilterHandler* = proc(msg: WakuMessage) {.gcsafe, closure.}

  Filter* = object
    contentFilters*: seq[ContentFilter]
    handler*: ContentFilterHandler

  # @TODO MAYBE MORE INFO?
  Filters* = Table[string, Filter]

  FilterRequest* = object
    contentFilters*: seq[ContentFilter]
    topic*: string
    subscribe*: bool

  MessagePush* = object
    messages*: seq[WakuMessage]

  FilterRPC* = object
    requestId*: string
    request*: FilterRequest
    push*: MessagePush

  Subscriber* = object
    peer*: PeerInfo
    requestId*: string
    filter*: FilterRequest # @TODO MAKE THIS A SEQUENCE AGAIN?

  MessagePushHandler* = proc(requestId: string, msg: MessagePush) {.gcsafe, closure.}

  FilterPeer* = object
    peerInfo*: PeerInfo

  WakuFilter* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    switch*: Switch
    peers*: seq[FilterPeer]
    subscribers*: seq[Subscriber]
    pushHandler*: MessagePushHandler
