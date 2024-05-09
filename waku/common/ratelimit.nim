when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/options, chronos/timer, libp2p/stream/connection

import ./tokenbucket

export tokenbucket

type RateLimitSetting* = tuple[volume: int, period: Duration]

# Set the default to switch off rate limiting for now
let DefaultGlobalNonRelayRateLimit*: RateLimitSetting = (0, 0.minutes)

proc newTokenBucket*(setting: Option[RateLimitSetting]): Option[TokenBucket] =
  if setting.isNone:
    return none[TokenBucket]()

  let (volume, period) = setting.get()
  if volume <= 0 or period <= 0.seconds:
    return none[TokenBucket]()

  return some(TokenBucket.new(volume, period))

proc checkUsage(
    t: var Option[TokenBucket], proto: string, conn: Connection
): bool {.raises: [].} =
  if t.isNone():
    return true

  let tokenBucket = t.get()
  if not tokenBucket.tryConsume(1):
    return false

  return true

template checkUsageLimit*(
    t: var Option[TokenBucket],
    proto: string,
    conn: Connection,
    bodyWithinLimit, bodyRejected: untyped,
) =
  if t.checkUsage(proto, conn):
    waku_service_requests.inc(labelValues = [proto])
    bodyWithinLimit
  else:
    waku_service_requests_rejected.inc(labelValues = [proto])
    bodyRejected

func `$`*(ob: Option[TokenBucket]): string {.inline.} =
  if ob.isNone():
    return "no-limit"

  return $ob.get()
