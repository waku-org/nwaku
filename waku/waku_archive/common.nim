when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/options, stew/results, stew/byteutils, stew/arrayops, nimcrypto/sha2
import ../waku_core, ../common/paging

## Waku message digest

type MessageDigest* {.deprecated.} = MDigest[256]

proc fromBytes*(T: type MessageDigest, src: seq[byte]): T {.deprecated.} =
  var data: array[32, byte]

  let byteCount = copyFrom[byte](data, src)

  assert byteCount == 32

  return MessageDigest(data: data)

proc computeDigest*(msg: WakuMessage): MessageDigest {.deprecated.} =
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
  ArchiveCursor* = WakuMessageHash

  ArchiveCursorV2* {.deprecated.} = object
    digest*: MessageDigest
    storeTime*: Timestamp
    senderTime*: Timestamp
    pubsubTopic*: PubsubTopic

  ArchiveQuery* = object
    includeData*: bool
    pubsubTopic*: Option[PubsubTopic]
    contentTopics*: seq[ContentTopic]
    cursor*: Option[ArchiveCursor]
    startTime*: Option[Timestamp]
    endTime*: Option[Timestamp]
    hashes*: seq[WakuMessageHash]
    pageSize*: uint
    direction*: PagingDirection

  ArchiveQueryV2* {.deprecated.} = object
    pubsubTopic*: Option[PubsubTopic]
    contentTopics*: seq[ContentTopic]
    cursor*: Option[ArchiveCursorV2]
    startTime*: Option[Timestamp]
    endTime*: Option[Timestamp]
    pageSize*: uint
    direction*: PagingDirection

  ArchiveResponse* = object
    cursor*: Option[ArchiveCursor]
    hashes*: seq[WakuMessageHash]
    topics*: seq[PubsubTopic]
    messages*: seq[WakuMessage]

  ArchiveResponseV2* {.deprecated.} = object
    messages*: seq[WakuMessage]
    topics*: seq[PubsubTopic]
    cursor*: Option[ArchiveCursorV2]

  ArchiveErrorKind* {.pure.} = enum
    UNKNOWN = uint32(0)
    DRIVER_ERROR = uint32(1)
    INVALID_QUERY = uint32(2)

  ArchiveError* = object
    case kind*: ArchiveErrorKind
    of DRIVER_ERROR, INVALID_QUERY:
      # TODO: Add an enum to be able to distinguish between error causes
      cause*: string
    else:
      discard

  ArchiveResult* = Result[ArchiveResponse, ArchiveError]

  ArchiveResultV2* {.deprecated.} = Result[ArchiveResponseV2, ArchiveError]

proc `$`*(err: ArchiveError): string =
  case err.kind
  of ArchiveErrorKind.DRIVER_ERROR:
    "DIRVER_ERROR: " & err.cause
  of ArchiveErrorKind.INVALID_QUERY:
    "INVALID_QUERY: " & err.cause
  of ArchiveErrorKind.UNKNOWN:
    "UNKNOWN"

proc invalidQuery*(T: type ArchiveError, cause: string): T =
  ArchiveError(kind: ArchiveErrorKind.INVALID_QUERY, cause: cause)
