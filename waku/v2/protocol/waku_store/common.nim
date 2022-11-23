when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  stew/byteutils,
  nimcrypto/sha2
import
  ../../utils/time,
  ../waku_message


const
  WakuStoreCodec* = "/vac/waku/store/2.0.0-beta4"

  DefaultPageSize*: uint64 = 20

  MaxPageSize*: uint64 = 100


type WakuStoreResult*[T] = Result[T, string]


## Waku message digest

type MessageDigest* = MDigest[256]

proc computeDigest*(msg: WakuMessage): MessageDigest =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.payload)

  # Computes the hash
  return ctx.finish()


## Public API types

type
  HistoryCursor* = object
    pubsubTopic*: PubsubTopic
    senderTime*: Timestamp
    storeTime*: Timestamp
    digest*: MessageDigest

  HistoryQuery* = object
    pubsubTopic*: Option[PubsubTopic]
    contentTopics*: seq[ContentTopic]
    cursor*: Option[HistoryCursor]
    startTime*: Option[Timestamp]
    endTime*: Option[Timestamp]
    pageSize*: uint64
    ascending*: bool

  HistoryResponse* = object
    messages*: seq[WakuMessage]
    cursor*: Option[HistoryCursor]

  HistoryErrorKind* {.pure.} = enum
    UNKNOWN = uint32(000)
    PEER_DIAL_FAILURE = uint32(200)
    BAD_RESPONSE = uint32(300)
    BAD_REQUEST = uint32(400)
    SERVICE_UNAVAILABLE = uint32(503)

  HistoryError* = object
    case kind*: HistoryErrorKind
    of PEER_DIAL_FAILURE:
      address*: string
    of BAD_RESPONSE, BAD_REQUEST:
      cause*: string
    else:
      discard

  HistoryResult* = Result[HistoryResponse, HistoryError]


proc parse*(T: type HistoryErrorKind, kind: uint32): T =
  case kind:
  of 000, 200, 300, 400, 503:
    HistoryErrorKind(kind)
  else:
    HistoryErrorKind.UNKNOWN

proc `$`*(err: HistoryError): string =
  case err.kind:
  of HistoryErrorKind.PEER_DIAL_FAILURE:
    "PEER_DIAL_FAILURE: " & err.address
  of HistoryErrorKind.BAD_RESPONSE:
    "BAD_RESPONSE: " & err.cause
  of HistoryErrorKind.BAD_REQUEST:
    "BAD_REQUEST: " & err.cause
  of HistoryErrorKind.SERVICE_UNAVAILABLE:
    "SERVICE_UNAVAILABLE"
  of HistoryErrorKind.UNKNOWN:
    "UNKNOWN"
