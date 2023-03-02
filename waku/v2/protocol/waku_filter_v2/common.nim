when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results

const
  WakuFilterSubscribeCodec* = "/vac/waku/filter-subscribe/2.0.0-beta1"
  WakuFilterPushCodec* = "/vac/waku/filter-push/2.0.0-beta1"

type
  FilterSubscribeErrorKind* {.pure.} = enum
    UNKNOWN = uint32(000)
    BAD_REQUEST = uint32(400)
    NOT_FOUND = uint32(404)
    SERVICE_UNAVAILABLE = uint32(503)

  FilterSubscribeError* = object
    kind*: FilterSubscribeErrorKind
    cause*: string

  FilterSubscribeResult* = Result[void, FilterSubscribeError]

# Convenience functions

proc badRequest*(T: type FilterSubscribeError, cause = "bad request"): FilterSubscribeError =
  FilterSubscribeError(
    kind: FilterSubscribeErrorKind.BAD_REQUEST,
    cause: cause)

proc notFound*(T: type FilterSubscribeError, cause = "peer has no subscriptions"): FilterSubscribeError =
  FilterSubscribeError(
    kind: FilterSubscribeErrorKind.NOT_FOUND,
    cause: cause)

proc serviceUnavailable*(T: type FilterSubscribeError, cause = "service unavailable"): FilterSubscribeError =
  FilterSubscribeError(
    kind: FilterSubscribeErrorKind.SERVICE_UNAVAILABLE,
    cause: cause)

proc `$`*(err: FilterSubscribeError): string =
  case err.kind:
  of FilterSubscribeErrorKind.BAD_REQUEST:
    "BAD_REQUEST: " & err.cause
  of FilterSubscribeErrorKind.NOT_FOUND:
    "NOT_FOUND: " & err.cause
  of FilterSubscribeErrorKind.SERVICE_UNAVAILABLE:
    "SERVICE_UNAVAILABLE: " & err.cause
  of FilterSubscribeErrorKind.UNKNOWN:
    "UNKNOWN"
