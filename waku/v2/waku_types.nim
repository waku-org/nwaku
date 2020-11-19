## Core Waku data types are defined here to avoid recursive dependencies.
##
## TODO Move more common data types here

import
  std/[tables, times],
  chronos, bearssl, stew/[byteutils, endians2],
  libp2p/[switch, peerinfo, multiaddress, crypto/crypto],
  libp2p/protobuf/minprotobuf,
  libp2p/protocols/protocol,
  libp2p/switch,
  libp2p/stream/connection,
  libp2p/protocols/pubsub/[pubsub, gossipsub],
  nimcrypto/sha2,
  sqlite3_abi,
  ./sqlite

# Constants required for pagination -------------------------------------------
const MaxPageSize* = 100 # Maximum number of waku messages in each page

# Common data types -----------------------------------------------------------
type
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

  QueryHandlerFunc* = proc(response: HistoryResponse) {.gcsafe, closure.}


  Index* = object
    ## This type contains the  description of an Index used in the pagination of WakuMessages
    digest*: MDigest[256]
    receivedTime*: float64

  IndexedWakuMessage* = object
    ## This type is used to encapsulate a WakuMessage and its Index
    msg*: WakuMessage
    index*: Index

  PagingDirection* {.pure.} = enum
    ## PagingDirection determines the direction of pagination
    BACKWARD = uint32(0)
    FORWARD = uint32(1)

  PagingInfo* = object
    ## This type holds the information needed for the pagination
    pageSize*: uint64
    cursor*: Index
    direction*: PagingDirection

  HistoryQuery* = object
    topics*: seq[ContentTopic]
    pagingInfo*: PagingInfo # used for pagination

  HistoryResponse* = object
    messages*: seq[WakuMessage]
    pagingInfo*: PagingInfo # used for pagination

  HistoryRPC* = object
    requestId*: string
    query*: HistoryQuery
    response*: HistoryResponse

  HistoryPeer* = object
    peerInfo*: PeerInfo

  MessageStoreResult*[T] = Result[T, string]

  Sqlite* = ptr sqlite3

  MessageStore* = ref object of RootObj
    database*: SqliteDatabase

  WakuStore* = ref object of LPProtocol
    switch*: Switch
    rng*: ref BrHmacDrbgContext
    peers*: seq[HistoryPeer]
    messages*: seq[IndexedWakuMessage]
    store*: MessageStore

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

  AccountHandler* = proc (peerId: PeerId, amount: int) {.gcsafe, closure.}

  WakuSwap* = ref object of LPProtocol
    switch*: Switch
    rng*: ref BrHmacDrbgContext
    #peers*: seq[PeerInfo]
    text*: string
    accounting*: Table[PeerId, int]
    accountFor*: AccountHandler

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuStore*: WakuStore
    wakuFilter*: WakuFilter
    wakuSwap*: WakuSwap
    peerInfo*: PeerInfo
    libp2pTransportLoops*: seq[Future[void]]
  # TODO Revist messages field indexing as well as if this should be Message or WakuMessage
    messages*: seq[(Topic, WakuMessage)]
    filters*: Filters
    subscriptions*: MessageNotificationSubscriptions
    rng*: ref BrHmacDrbgContext

  WakuRelay* = ref object of GossipSub
    gossipEnabled*: bool

  WakuInfo* = object
    # NOTE One for simplicity, can extend later as needed
    listenStr*: string
    #multiaddrStrings*: seq[string]

  WakuResult*[T] = Result[T, cstring]

  Beneficiary* = seq[byte]

  # TODO Consider adding payment threshhold and terms field
  Handshake* = object
    beneficiary*: Beneficiary

  Cheque* = object
    beneficiary*: Beneficiary
    date*: uint32
    amount*: uint32

  AccountUpdateFunc* = proc(peerId: PeerId, amount: int) {.gcsafe.}


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

proc computeIndex*(msg: WakuMessage): Index =
  ## Takes a WakuMessage and returns its Index 
  var ctx: sha256
  ctx.init()
  ctx.update(msg.contentTopic.toBytes()) # converts the contentTopic to bytes
  ctx.update(msg.payload)
  let digest = ctx.finish() # computes the hash
  ctx.clear()
  result.digest = digest
  result.receivedTime = epochTime() # gets the unix timestamp

