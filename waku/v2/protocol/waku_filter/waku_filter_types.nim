import
  std/[tables],
  chronos,
  bearssl,
  libp2p/protocols/protocol,
  ../../node/peer_manager/peer_manager,
  ../waku_message

export waku_message

const
  # We add a 64kB safety buffer for protocol overhead.
  # 10x-multiplier also for safety: currently we never
  # push more than 1 message at a time.
  MaxRpcSize* = 10 * MaxWakuMessageSize + 64*1024

type
  PubSubTopic* = string

  ContentFilter* = object
    contentTopic*: ContentTopic

  ContentFilterHandler* = proc(msg: WakuMessage) {.gcsafe, closure, raises: [Defect].}

  Filter* = object
    contentFilters*: seq[ContentFilter]
    pubSubTopic*: PubSubTopic
    handler*: ContentFilterHandler

  # @TODO MAYBE MORE INFO?
  Filters* = Table[string, Filter]

  FilterRequest* = object
    contentFilters*: seq[ContentFilter]
    pubSubTopic*: PubSubTopic
    subscribe*: bool

  MessagePush* = object
    messages*: seq[WakuMessage]

  FilterRPC* = object
    requestId*: string
    request*: FilterRequest
    push*: MessagePush

  Subscriber* = object
    peer*: PeerID
    requestId*: string
    filter*: FilterRequest # @TODO MAKE THIS A SEQUENCE AGAIN?

  MessagePushHandler* = proc(requestId: string, msg: MessagePush): Future[void] {.gcsafe, closure.}

  WakuFilter* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    peerManager*: PeerManager
    subscribers*: seq[Subscriber]
    pushHandler*: MessagePushHandler
    failedPeers*: Table[string, chronos.Moment]
    timeout*: chronos.Duration
