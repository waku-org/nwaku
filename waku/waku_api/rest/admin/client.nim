{.push raises: [].}

import chronicles, json_serialization, presto/[route, client], stew/byteutils

import ../serdes, ../rest_serdes, ./types

export types

logScope:
  topics = "waku node rest admin api"

proc encodeBytes*(value: seq[string], contentType: string): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc getPeers*(): RestResponse[seq[WakuPeer]] {.
  rest, endpoint: "/admin/v1/peers", meth: HttpMethod.MethodGet
.}

proc postPeers*(
  body: seq[string]
): RestResponse[string] {.
  rest, endpoint: "/admin/v1/peers", meth: HttpMethod.MethodPost
.}

proc getFilterSubscriptions*(): RestResponse[seq[FilterSubscription]] {.
  rest, endpoint: "/admin/v1/filter/subscriptions", meth: HttpMethod.MethodGet
.}

proc getFilterSubscriptionsFilterNotMounted*(): RestResponse[string] {.
  rest, endpoint: "/admin/v1/filter/subscriptions", meth: HttpMethod.MethodGet
.}
