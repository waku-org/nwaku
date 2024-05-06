when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/options
import chronos/timer
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
