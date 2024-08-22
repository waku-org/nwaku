{.push raises: [].}

import std/[options, sequtils], results, stew/byteutils, nimcrypto/sha2
import ../waku_core, ../common/paging

const
  WakuLegacyStoreCodec* = "/vac/waku/store/2.0.0-beta4"

  DefaultPageSize*: uint64 = 20

  MaxPageSize*: uint64 = 100

type WakuStoreResult*[T] = Result[T, string]

## Waku message digest

type MessageDigest* = MDigest[256]

proc computeDigest*(msg: WakuMessage): MessageDigest =
  var ctx: sha256
  ctx.init()
  defer:
    ctx.clear()

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
    direction*: PagingDirection
    requestId*: string

  HistoryResponse* = object
    messages*: seq[WakuMessage]
    cursor*: Option[HistoryCursor]

  HistoryErrorKind* {.pure.} = enum
    UNKNOWN = uint32(000)
    BAD_RESPONSE = uint32(300)
    BAD_REQUEST = uint32(400)
    TOO_MANY_REQUESTS = uint32(429)
    SERVICE_UNAVAILABLE = uint32(503)
    PEER_DIAL_FAILURE = uint32(504)

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
  case kind
  of 000, 200, 300, 400, 429, 503:
    HistoryErrorKind(kind)
  else:
    HistoryErrorKind.UNKNOWN

proc `$`*(err: HistoryError): string =
  case err.kind
  of HistoryErrorKind.PEER_DIAL_FAILURE:
    "PEER_DIAL_FAILURE: " & err.address
  of HistoryErrorKind.BAD_RESPONSE:
    "BAD_RESPONSE: " & err.cause
  of HistoryErrorKind.BAD_REQUEST:
    "BAD_REQUEST: " & err.cause
  of HistoryErrorKind.TOO_MANY_REQUESTS:
    "TOO_MANY_REQUESTS"
  of HistoryErrorKind.SERVICE_UNAVAILABLE:
    "SERVICE_UNAVAILABLE"
  of HistoryErrorKind.UNKNOWN:
    "UNKNOWN"

proc checkHistCursor*(self: HistoryCursor): Result[void, HistoryError] =
  if self.pubsubTopic.len == 0:
    return err(HistoryError(kind: BAD_REQUEST, cause: "empty pubsubTopic"))
  if self.senderTime == 0:
    return err(HistoryError(kind: BAD_REQUEST, cause: "invalid senderTime"))
  if self.storeTime == 0:
    return err(HistoryError(kind: BAD_REQUEST, cause: "invalid storeTime"))
  if self.digest.data.all(
    proc(x: byte): bool =
      x == 0
  ):
    return err(HistoryError(kind: BAD_REQUEST, cause: "empty digest"))
  return ok()
