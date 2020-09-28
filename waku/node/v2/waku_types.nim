## Core Waku data types are defined here to avoid recursive dependencies.
##
## TODO Move more common data types here

import
  std/tables,
  chronos,
  bearssl,
  libp2p/[switch, peerinfo, multiaddress, crypto/crypto],
  libp2p/protobuf/minprotobuf,
  libp2p/protocols/protocol,
  libp2p/switch,
  libp2p/stream/connection,
  libp2p/protocols/pubsub/[pubsub, floodsub, gossipsub]

# Common data types -----------------------------------------------------------

type
  Topic* = string
  Message* = seq[byte]

  # TODO: these filter structures can be simplified but like this for now to
  # match Node API
  # Also, should reuse in filter/wakufilter code, but cyclic imports right now.
  ContentFilter* = object
    topics*: seq[string]

  ContentFilterHandler* = proc(message: seq[byte]) {.gcsafe, closure.}

  Filter* = object
    contentFilter*: ContentFilter
    handler*: ContentFilterHandler

  Filters* = Table[string, Filter]

  WakuMessage* = object
    payload*: seq[byte]
    contentTopic*: string

  MessageNotificationHandler* = proc(topic: string, msg: WakuMessage): Future[void] {.gcsafe, closure.}

  MessageNotificationSubscriptions* = TableRef[string, MessageNotificationSubscription]

  MessageNotificationSubscription* = object
    topics*: seq[string] # @TODO TOPIC
    handler*: MessageNotificationHandler

  QueryHandlerFunc* = proc(response: HistoryResponse) {.gcsafe, closure.}

  HistoryQuery* = object
    topics*: seq[string]

  HistoryResponse* = object
    messages*: seq[WakuMessage]

  HistoryRPC* = object
    requestId*: string
    query*: HistoryQuery
    response*: HistoryResponse

  HistoryPeer* = object
    peerInfo*: PeerInfo

  WakuStore* = ref object of LPProtocol
    switch*: Switch
    rng*: ref BrHmacDrbgContext
    peers*: seq[HistoryPeer]
    messages*: seq[WakuMessage]

  FilterRequest* = object
    contentFilter*: seq[ContentFilter]
    topic*: string

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

  MessagePushHandler* = proc(msg: MessagePush): Future[void] {.gcsafe, closure.}

  WakuFilter* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    switch*: Switch
    subscribers*: seq[Subscriber]
    pushHandler*: MessagePushHandler

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuStore*: WakuStore
    wakuFilter*: WakuFilter
    peerInfo*: PeerInfo
    libp2pTransportLoops*: seq[Future[void]]
  # TODO Revist messages field indexing as well as if this should be Message or WakuMessage
    messages*: seq[(Topic, WakuMessage)]
    filters*: Filters
    subscriptions*: MessageNotificationSubscriptions
    rng*: ref BrHmacDrbgContext

  WakuRelay* = ref object of GossipSub
    gossipEnabled*: bool

# Encoding and decoding -------------------------------------------------------

proc init*(T: type WakuMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuMessage()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, msg.payload)
  discard ? pb.getField(2, msg.contentTopic)

  ok(msg)

proc encode*(message: WakuMessage): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, message.payload)
  result.write(2, message.contentTopic)

proc notify*(filters: Filters, msg: WakuMessage) =
  for filter in filters.values:
    # TODO: In case of no topics we should either trigger here for all messages,
    # or we should not allow such filter to exist in the first place.
    if filter.contentFilter.topics.len > 0:
      if msg.contentTopic in filter.contentFilter.topics:
        filter.handler(msg.payload)

proc generateRequestId*(rng: ref BrHmacDrbgContext): string =
  let 
    rngPtr = rng[].unsafeAddr # doesn't escape
    length = 10
  var bytes: array[10, byte]
  brHmacDrbgGenerate(rngPtr, bytes[0].addr, csize_t length)
  toHex(bytes)
