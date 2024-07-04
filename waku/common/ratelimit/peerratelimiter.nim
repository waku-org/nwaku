{.push raises: [].}

import std/[options, tables], chronos/timer, libp2p/stream/connection, libp2p/utility

import ./[simpleratelimiter, waku_service_metrics], ../../utils/tableutils

export tokenbucket, ratelimitsetting, waku_service_metrics

type PeerRateLimiter* = ref object of RootObj
  setting*: Option[RateLimitSetting]
  peerBucket: Table[PeerId, Option[TokenBucket]]

proc mgetOrPut(
    peerRateLimiter: var PeerRateLimiter, peerId: PeerId
): var Option[TokenBucket] =
  return peerRateLimiter.peerBucket.mgetOrPut(
    peerId, newTokenBucket(peerRateLimiter.setting, ReplenishMode.Compensating)
  )

template checkUsageLimit*(
    t: var PeerRateLimiter,
    proto: string,
    conn: Connection,
    bodyWithinLimit, bodyRejected: untyped,
) =
  checkUsageLimit(t.mgetOrPut(conn.peerId), proto, conn, bodyWithinLimit, bodyRejected)

proc unregister*(peerRateLimiter: var PeerRateLimiter, peerId: PeerId) =
  peerRateLimiter.peerBucket.del(peerId)

proc unregister*(peerRateLimiter: var PeerRateLimiter, peerIds: seq[PeerId]) =
  peerRateLimiter.peerBucket.keepItIf(key notin peerIds)
