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
  ../waku_core,
  ../common/paging


## Waku message digest
# TODO: Move this into the driver implementations. We should be passing
#  here a buffer containing a serialized implementation dependent cursor.

type MessageDigest* = MDigest[256]

proc computeDigest*(msg: WakuMessage): MessageDigest =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.payload)

  # Computes the hash
  return ctx.finish()


# TODO: Move this into the driver implementations. We should be passing
#  here a buffer containing a serialized implementation dependent cursor.
type DbCursor = object
    pubsubTopic*: PubsubTopic
    senderTime*: Timestamp
    storeTime*: Timestamp
    digest*: MessageDigest


## Public API types

type
  # TODO: We should be passing here a buffer containing a serialized
  # implementation dependent cursor. Waku archive logic should be independent
  # of the cursor format.
  ArchiveCursor* = DbCursor

  ArchiveQuery* = object
    pubsubTopic*: Option[PubsubTopic]
    contentTopics*: seq[ContentTopic]
    cursor*: Option[ArchiveCursor]
    startTime*: Option[Timestamp]
    endTime*: Option[Timestamp]
    pageSize*: uint
    direction*: PagingDirection

  ArchiveResponse* = object
    messages*: seq[WakuMessage]
    cursor*: Option[ArchiveCursor]

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


proc `$`*(err: ArchiveError): string =
  case err.kind:
  of ArchiveErrorKind.DRIVER_ERROR:
    "DIRVER_ERROR: " & err.cause
  of ArchiveErrorKind.INVALID_QUERY:
    "INVALID_QUERY: " & err.cause
  of ArchiveErrorKind.UNKNOWN:
    "UNKNOWN"

proc invalidQuery*(T: type ArchiveError, cause: string): T =
  ArchiveError(kind: ArchiveErrorKind.INVALID_QUERY, cause: cause)
