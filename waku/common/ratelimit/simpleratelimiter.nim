{.push raises: [].}

import std/[options], chronos/timer, libp2p/stream/connection, libp2p/utility

import ./[tokenbucket, ratelimitsetting, waku_service_metrics]
export tokenbucket, ratelimitsetting, waku_service_metrics

proc newTokenBucket*(
    setting: Option[RateLimitSetting],
    replenishMode: ReplenishMode = ReplenishMode.Compensating,
): Option[TokenBucket] =
  if setting.isNone:
    return none[TokenBucket]()

  if setting.get().isUnlimited():
    return none[TokenBucket]()

  return some(TokenBucket.new(setting.get().volume, setting.get().period))

proc checkUsage(
    t: var TokenBucket, proto: string, conn: Connection, now = Moment.now()
): bool {.raises: [].} =
  if not t.tryConsume(1, now):
    return false

  return true

proc checkUsage(
    t: var Option[TokenBucket], proto: string, conn: Connection, now = Moment.now()
): bool {.raises: [].} =
  if t.isNone():
    return true

  var tokenBucket = t.get()
  return checkUsage(tokenBucket, proto, conn, now)

template checkUsageLimit*(
    t: var Option[TokenBucket] | var TokenBucket,
    proto: string,
    conn: Connection,
    bodyWithinLimit, bodyRejected: untyped,
) =
  if t.checkUsage(proto, conn):
    waku_service_requests.inc(labelValues = [proto, "served"])
    bodyWithinLimit
  else:
    waku_service_requests.inc(labelValues = [proto, "rejected"])
    bodyRejected
