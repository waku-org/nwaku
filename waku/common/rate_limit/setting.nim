{.push raises: [].}

import chronos/timer

type RateLimitSetting* = tuple[volume: int, period: Duration]

# Set the default to switch off rate limiting for now
let DefaultGlobalNonRelayRateLimit*: RateLimitSetting = (0, 0.minutes)

proc isUnlimited*(t: RateLimitSetting): bool {.inline.} =
  return t.volume <= 0 or t.period <= 0.seconds

func `$`*(t: RateLimitSetting): string {.inline.} =
  return
    if t.isUnlimited():
      "no-limit"
    else:
      $t.volume & "/" & $t.period
