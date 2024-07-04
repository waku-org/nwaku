{.push raises: [].}

import
  std/[options, math],
  chronicles,
  chronos/timer,
  libp2p/stream/connection,
  libp2p/utility

import ./[simpleratelimiter, waku_service_metrics], ../utils/timedmap

export tokenbucket, ratelimitsetting, waku_service_metrics

logScope:
  topics = "waku ratelimit"

type RequestRateLimiter* = ref object of RootObj
  tokenBucket: Option[TokenBucket]
  setting*: Option[RateLimitSetting]
  peerBucketSetting*: RateLimitSetting
  peerUsage: TimedMap[PeerId, TokenBucket]

proc mgetOrPut(
    requestRateLimiter: var RequestRateLimiter, peerId: PeerId
): var TokenBucket =
  let bucketForNew = newTokenBucket(some(requestRateLimiter.peerBucketSetting)).valueOr:
    raiseAssert "This branch is not allowed to be reached."

  return requestRateLimiter.peerUsage.mgetOrPut(peerId, bucketForNew)

proc checkUsage*(
    t: var RequestRateLimiter, proto: string, conn: Connection, now = Moment.now()
): bool {.raises: [].} =
  if t.tokenBucket.isNone():
    return true

  let peerBucket = t.mgetOrPut(conn.peerId)
  ## check requesting peer's usage is not over the calculated ratio and let that peer go which not requested much/or this time...
  if not peerBucket.tryConsume(1, now):
    trace "peer usage limit reached", peer = conn.peerId
    return false

  # Ok if the peer can consume, check the overall budget we have left
  let tokenBucket = t.tokenBucket.get()
  if not tokenBucket.tryConsume(1, now):
    return false

  return true

template checkUsageLimit*(
    t: var RequestRateLimiter,
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

# TODO: review these ratio assumptions! Debatable!
func calcPeriodRatio(settingOpt: Option[RateLimitSetting]): int =
  settingOpt.withValue(setting):
    if setting.isUnlimited():
      return 0

    if setting.period <= 1.seconds:
      return 10

    if setting.period <= 1.minutes:
      return 3

    return 2
  do:
    return 0

# calculates peer cache items timeout
# effectively if a peer does not issue any requests for this amount of time will be forgotten.
func calcCacheTimeout(settingOpt: Option[RateLimitSetting], ratio: int): Duration =
  settingopt.withValue(setting):
    if setting.isUnlimited():
      return 0.seconds

    return setting.period * ratio * 2
  do:
    return 0.seconds

func calcPeerTokenSetting(
    setting: Option[RateLimitSetting], ratio: int
): RateLimitSetting =
  let s = setting.valueOr:
    return (0, 0.minutes)

  let peerVolume = trunc((s.volume * ratio).float * 0.75).int
  let peerPeriod = s.period * ratio

  return (peerVolume, peerPeriod)

proc newRequestRateLimiter*(setting: Option[RateLimitSetting]): RequestRateLimiter =
  let ratio = calcPeriodRatio(setting)
  return RequestRateLimiter(
    tokenBucket: newTokenBucket(setting),
    setting: setting,
    peerBucketSetting: calcPeerTokenSetting(setting, ratio),
    peerUsage: init(TimedMap[PeerId, TokenBucket], calcCacheTimeout(setting, ratio)),
  )
