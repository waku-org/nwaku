{.push raises: [].}

import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client],
  stew/byteutils

import ../serdes, ../responses, ../rest_serdes, ./types

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

proc getPeerById*(
  peerId: string
): RestResponse[WakuPeer] {.
  rest, endpoint: "/admin/v1/peer/{peerId}", meth: HttpMethod.MethodGet
.}

proc getConnectedPeers*(): RestResponse[seq[WakuPeer]] {.
  rest, endpoint: "/admin/v1/peers/connected", meth: HttpMethod.MethodGet
.}

proc getConnectedPeersByShard*(
  shardId: uint16
): RestResponse[seq[WakuPeer]] {.
  rest, endpoint: "/admin/v1/peers/connected/on/{shardId}", meth: HttpMethod.MethodGet
.}

proc getConnectedRelayPeers*(): RestResponse[seq[PeersOfShards]] {.
  rest, endpoint: "/admin/v1/peers/connected/relay", meth: HttpMethod.MethodGet
.}

proc getConnectedRelayPeersByShard*(
  shardId: uint16
): RestResponse[PeersOfShards] {.
  rest,
  endpoint: "/admin/v1/peers/connected/relay/on/{shardId}",
  meth: HttpMethod.MethodGet
.}

proc getMeshPeers*(): RestResponse[seq[PeersOfShards]] {.
  rest, endpoint: "/admin/v1/peers/mesh", meth: HttpMethod.MethodGet
.}

proc getMeshPeersByShard*(
  shardId: uint16
): RestResponse[PeersOfShards] {.
  rest, endpoint: "/admin/v1/peers/mesh/on/{shardId}", meth: HttpMethod.MethodGet
.}

proc getFilterSubscriptions*(): RestResponse[seq[FilterSubscription]] {.
  rest, endpoint: "/admin/v1/filter/subscriptions", meth: HttpMethod.MethodGet
.}

proc getFilterSubscriptionsFilterNotMounted*(): RestResponse[string] {.
  rest, endpoint: "/admin/v1/filter/subscriptions", meth: HttpMethod.MethodGet
.}
