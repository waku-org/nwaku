## Types for waku_store protocol.

import
  bearssl,
  libp2p/peerinfo,
  libp2p/protocols/protocol,
  ../waku_swap/waku_swap_types,
  ../waku_message,
  ../../node/storage/message/message_store,
  ../../utils/pagination,
  ../../node/peer_manager/peer_manager

export waku_message
export pagination

# Constants required for pagination -------------------------------------------
const MaxPageSize* = uint64(100) # Maximum number of waku messages in each page

type
  HistoryContentFilter* = object
    contentTopic*: ContentTopic

  QueryHandlerFunc* = proc(response: HistoryResponse) {.gcsafe, closure.}

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
    contentFilters*: seq[HistoryContentFilter]
    pagingInfo*: PagingInfo # used for pagination
    startTime*: float64 # used for time-window query
    endTime*: float64 # used for time-window query

  HistoryResponse* = object
    messages*: seq[WakuMessage]
    pagingInfo*: PagingInfo # used for pagination

  HistoryRPC* = object
    requestId*: string
    query*: HistoryQuery
    response*: HistoryResponse

  WakuStore* = ref object of LPProtocol
    peerManager*: PeerManager
    rng*: ref BrHmacDrbgContext
    messages*: seq[IndexedWakuMessage]
    store*: MessageStore
    wakuSwap*: WakuSwap
