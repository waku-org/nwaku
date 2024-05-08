when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options], stew/results
import ../waku_core, ../common/paging

const
  WakuStoreCodec* = "/vac/waku/store-query/3.0.0"

  DefaultPageSize*: uint64 = 20

  MaxPageSize*: uint64 = 100

  EmptyCursor*: WakuMessageHash = EmptyWakuMessageHash

type WakuStoreResult*[T] = Result[T, string]

## Public API types

type
  StoreQueryRequest* = object
    requestId*: string
    includeData*: bool

    pubsubTopic*: Option[PubsubTopic]
    contentTopics*: seq[ContentTopic]
    startTime*: Option[Timestamp]
    endTime*: Option[Timestamp]

    messageHashes*: seq[WakuMessageHash]

    paginationCursor*: Option[WakuMessageHash]
    paginationForward*: PagingDirection
    paginationLimit*: Option[uint64]

  WakuMessageKeyValue* = object
    messageHash*: WakuMessageHash
    message*: Option[WakuMessage]
    pubsubTopic*: Option[PubsubTopic]

  StoreQueryResponse* = object
    requestId*: string

    statusCode*: uint32
    statusDesc*: string

    messages*: seq[WakuMessageKeyValue]

    paginationCursor*: Option[WakuMessageHash]

  StatusCode* {.pure.} = enum
    UNKNOWN = uint32(000)
    SUCCESS = uint32(200)
    BAD_RESPONSE = uint32(300)
    BAD_REQUEST = uint32(400)
    TOO_MANY_REQUESTS = uint32(429)
    SERVICE_UNAVAILABLE = uint32(503)
    PEER_DIAL_FAILURE = uint32(504)

  ErrorCode* {.pure.} = enum
    UNKNOWN = uint32(000)
    BAD_RESPONSE = uint32(300)
    BAD_REQUEST = uint32(400)
    TOO_MANY_REQUESTS = uint32(429)
    SERVICE_UNAVAILABLE = uint32(503)
    PEER_DIAL_FAILURE = uint32(504)

  StoreError* = object
    case kind*: ErrorCode
    of ErrorCode.PEER_DIAL_FAILURE:
      address*: string
    of ErrorCode.BAD_RESPONSE, ErrorCode.BAD_REQUEST:
      cause*: string
    else:
      discard

  StoreQueryResult* = Result[StoreQueryResponse, StoreError]

proc into*(errCode: ErrorCode): StatusCode =
  StatusCode(uint32(errCode))

proc new*(T: type StoreError, code: uint32, desc: string): T =
  let kind = ErrorCode.parse(code)

  case kind
  of ErrorCode.BAD_RESPONSE:
    return StoreError(kind: kind, cause: desc)
  of ErrorCode.BAD_REQUEST:
    return StoreError(kind: kind, cause: desc)
  of ErrorCode.TOO_MANY_REQUESTS:
    return StoreError(kind: kind)
  of ErrorCode.SERVICE_UNAVAILABLE:
    return StoreError(kind: kind)
  of ErrorCode.PEER_DIAL_FAILURE:
    return StoreError(kind: kind, address: desc)
  of ErrorCode.UNKNOWN:
    return StoreError(kind: kind)

proc parse*(T: type ErrorCode, kind: uint32): T =
  case kind
  of 000, 300, 400, 429, 503, 504:
    ErrorCode(kind)
  else:
    ErrorCode.UNKNOWN

proc `$`*(err: StoreError): string =
  case err.kind
  of ErrorCode.PEER_DIAL_FAILURE:
    "PEER_DIAL_FAILURE: " & err.address
  of ErrorCode.BAD_RESPONSE:
    "BAD_RESPONSE: " & err.cause
  of ErrorCode.BAD_REQUEST:
    "BAD_REQUEST: " & err.cause
  of ErrorCode.TOO_MANY_REQUESTS:
    "TOO_MANY_REQUESTS"
  of ErrorCode.SERVICE_UNAVAILABLE:
    "SERVICE_UNAVAILABLE"
  of ErrorCode.UNKNOWN:
    "UNKNOWN"
