## Core Waku data types are defined here to avoid recursive dependencies.
##
## TODO Move types here into their appropriate place

import
  std/tables,
  chronos, bearssl, stew/byteutils,
  libp2p/[switch, peerinfo, multiaddress, crypto/crypto],
  libp2p/protobuf/minprotobuf,
  libp2p/protocols/protocol,
  libp2p/switch,
  libp2p/stream/connection,
  libp2p/protocols/pubsub/[pubsub, gossipsub],
  nimcrypto/sha2,
  ./node/sqlite

# Constants required for pagination -------------------------------------------
const MaxPageSize* = 100 # Maximum number of waku messages in each page

# Common data types -----------------------------------------------------------
type

  Index* = object
    ## This type contains the  description of an Index used in the pagination of WakuMessages
    digest*: MDigest[256]
    receivedTime*: float64

  ContentTopic* = uint32

  Topic* = string
  Message* = seq[byte]

  WakuMessage* = object
    payload*: seq[byte]
    contentTopic*: ContentTopic
    version*: uint32

  MessageNotificationHandler* = proc(topic: string, msg: WakuMessage): Future[
      void] {.gcsafe, closure.}

  MessageNotificationSubscriptions* = TableRef[string, MessageNotificationSubscription]

  MessageNotificationSubscription* = object
    topics*: seq[string] # @TODO TOPIC
    handler*: MessageNotificationHandler

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

  ContentFilter* = object
    topics*: seq[ContentTopic]

  ContentFilterHandler* = proc(msg: WakuMessage) {.gcsafe, closure.}

  Filter* = object
    contentFilters*: seq[ContentFilter]
    handler*: ContentFilterHandler

  # @TODO MAYBE MORE INFO?
  Filters* = Table[string, Filter]

  WakuRelay* = ref object of GossipSub

  WakuInfo* = object
    # NOTE One for simplicity, can extend later as needed
    listenStr*: string
    #multiaddrStrings*: seq[string]

  WakuResult*[T] = Result[T, cstring]

  MessageStoreResult*[T] = Result[T, string]

  MessageStore* = ref object of RootObj
    database*: SqliteDatabase

# Encoding and decoding -------------------------------------------------------
# TODO Move out to to waku_message module
# Possibly same with util functions
proc init*(T: type WakuMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuMessage()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, msg.payload)
  discard ? pb.getField(2, msg.contentTopic)
  discard ? pb.getField(3, msg.version)

  ok(msg)

proc encode*(message: WakuMessage): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, message.payload)
  result.write(2, message.contentTopic)
  result.write(3, message.version)

proc notify*(filters: Filters, msg: WakuMessage, requestId: string = "") =
  for key in filters.keys:
    let filter = filters[key]
    # We do this because the key for the filter is set to the requestId received from the filter protocol.
    # This means we do not need to check the content filter explicitly as all MessagePushs already contain
    # the requestId of the coresponding filter.
    if requestId != "" and requestId == key:
      filter.handler(msg)
      continue

    # TODO: In case of no topics we should either trigger here for all messages,
    # or we should not allow such filter to exist in the first place.
    for contentFilter in filter.contentFilters:
      if contentFilter.topics.len > 0:
        if msg.contentTopic in contentFilter.topics:
          filter.handler(msg)
          break

proc generateRequestId*(rng: ref BrHmacDrbgContext): string =
  var bytes: array[10, byte]
  brHmacDrbgGenerate(rng[], bytes)
  toHex(bytes)
