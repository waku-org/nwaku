{.push raises: [].}

import stew/results

const
  WakuFilterSubscribeCodec* = "/vac/waku/filter-subscribe/2.0.0-beta1"
  WakuFilterPushCodec* = "/vac/waku/filter-push/2.0.0-beta1"

type
  FilterSubscribeErrorKind* {.pure.} = enum
    UNKNOWN = uint32(000)
    BAD_RESPONSE = uint32(300)
    BAD_REQUEST = uint32(400)
    NOT_FOUND = uint32(404)
    SERVICE_UNAVAILABLE = uint32(503)
    PEER_DIAL_FAILURE = uint32(504)

  FilterSubscribeError* = object
    case kind*: FilterSubscribeErrorKind
    of PEER_DIAL_FAILURE:
      address*: string
    of BAD_RESPONSE, BAD_REQUEST, NOT_FOUND, SERVICE_UNAVAILABLE:
      cause*: string
    else:
      discard

  FilterSubscribeResult* = Result[void, FilterSubscribeError]

# Convenience functions
proc peerDialFailure*(
    T: type FilterSubscribeError, address: string
): FilterSubscribeError =
  FilterSubscribeError(
    kind: FilterSubscribeErrorKind.PEER_DIAL_FAILURE, address: address
  )

proc badResponse*(
    T: type FilterSubscribeError, cause = "bad response"
): FilterSubscribeError =
  FilterSubscribeError(kind: FilterSubscribeErrorKind.BAD_RESPONSE, cause: cause)

proc badRequest*(
    T: type FilterSubscribeError, cause = "bad request"
): FilterSubscribeError =
  FilterSubscribeError(kind: FilterSubscribeErrorKind.BAD_REQUEST, cause: cause)

proc notFound*(
    T: type FilterSubscribeError, cause = "peer has no subscriptions"
): FilterSubscribeError =
  FilterSubscribeError(kind: FilterSubscribeErrorKind.NOT_FOUND, cause: cause)

proc serviceUnavailable*(
    T: type FilterSubscribeError, cause = "service unavailable"
): FilterSubscribeError =
  FilterSubscribeError(kind: FilterSubscribeErrorKind.SERVICE_UNAVAILABLE, cause: cause)

proc parse*(T: type FilterSubscribeErrorKind, kind: uint32): T =
  case kind
  of 000, 200, 300, 400, 404, 503:
    FilterSubscribeErrorKind(kind)
  else:
    FilterSubscribeErrorKind.UNKNOWN

proc parse*(T: type FilterSubscribeError, kind: uint32, cause = "", address = ""): T =
  let kind = FilterSubscribeErrorKind.parse(kind)
  case kind
  of PEER_DIAL_FAILURE:
    FilterSubscribeError(kind: kind, address: address)
  of BAD_RESPONSE, BAD_REQUEST, NOT_FOUND, SERVICE_UNAVAILABLE:
    FilterSubscribeError(kind: kind, cause: cause)
  else:
    FilterSubscribeError(kind: kind)

proc `$`*(err: FilterSubscribeError): string =
  case err.kind
  of FilterSubscribeErrorKind.PEER_DIAL_FAILURE:
    "PEER_DIAL_FAILURE: " & err.address
  of FilterSubscribeErrorKind.BAD_RESPONSE:
    "BAD_RESPONSE: " & err.cause
  of FilterSubscribeErrorKind.BAD_REQUEST:
    "BAD_REQUEST: " & err.cause
  of FilterSubscribeErrorKind.NOT_FOUND:
    "NOT_FOUND: " & err.cause
  of FilterSubscribeErrorKind.SERVICE_UNAVAILABLE:
    "SERVICE_UNAVAILABLE: " & err.cause
  of FilterSubscribeErrorKind.UNKNOWN:
    "UNKNOWN"
