when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

const
  WakuFilterSubscribeCodec* = "/vac/waku/filter-subscribe/2.0.0-beta1"
  WakuFilterPushCodec* = "/vac/waku/filter-push/2.0.0-beta1"

type
  FilterSubscribeErrorKind* {.pure.} = enum
    UNKNOWN = uint32(000)
    BAD_REQUEST = uint32(400)
    NOT_FOUND = uint32(404)

  FilterSubscribeError* = object
    kind*: FilterSubscribeErrorKind
    cause*: string

  FilterSubscribeResult* = Result[void, FilterSubscribeError]

proc `$`*(err: FilterSubscribeError): string =
  case err.kind:
  of FilterSubscribeErrorKind.BAD_REQUEST:
    "BAD_REQUEST: " & err.cause
  of FilterSubscribeErrorKind.NOT_FOUND:
    "NOT_FOUND: " & err.cause
  of FilterSubscribeErrorKind.UNKNOWN:
    "UNKNOWN"
