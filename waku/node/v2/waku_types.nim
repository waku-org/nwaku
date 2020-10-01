## Core Waku data types are defined here to avoid recursive dependencies.
##
## TODO Move more common data types here

import
  std/tables,
  chronos, bearssl, stew/byteutils,
  libp2p/[switch, peerinfo, multiaddress, crypto/crypto],
  libp2p/protobuf/minprotobuf,
  libp2p/protocols/protocol,
  libp2p/switch,
  libp2p/stream/connection,
  libp2p/protocols/pubsub/[pubsub, gossipsub]

# Common data types -----------------------------------------------------------

type
  Topic* = string
  Message* = seq[byte]

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
    contentFilters*: seq[ContentFilter]
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

  MessagePushHandler* = proc(requestId: string, msg: MessagePush) {.gcsafe, closure.}

  FilterPeer* = object
    peerInfo*: PeerInfo

  WakuFilter* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    switch*: Switch
    peers*: seq[FilterPeer]
    subscribers*: seq[Subscriber]
    pushHandler*: MessagePushHandler

  ContentFilter* = object
    topics*: seq[string]

  ContentFilterHandler* = proc(msg: MessagePush) {.gcsafe, closure.}

  # @TODO MAYBE MORE INFO?
  Filters* = Table[string, ContentFilterHandler]

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

proc generateRequestId*(rng: ref BrHmacDrbgContext): string =
  var bytes: array[10, byte]
  brHmacDrbgGenerate(rng[], bytes)
  toHex(bytes)
