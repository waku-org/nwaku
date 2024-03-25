{.push raises: [].}

import chronos

## This is an extract from chronos/ratelimit.nim due to the found bug in the original implementation.
## Unfortunately that bug cannot be solved without harm the original features of TokenBucket class.
## So, this current shortcut is used to enable move ahead with nwaku rate limiter implementation.
type TokenBucket* = ref object
  budget*: int
  budgetCap: int
  lastUpdate: Moment
  lastTimeFull: Moment
  fillDuration: Duration

proc update(bucket: TokenBucket, currentTime: Moment) =
  if bucket.fillDuration == default(Duration):
    bucket.budget = min(bucket.budgetCap, bucket.budget)
    return

  if currentTime < bucket.lastUpdate:
    return

  let timeDeltaFromLastFull = currentTime - bucket.lastTimeFull

  if timeDeltaFromLastFull.milliseconds < bucket.fillDuration.milliseconds:
    return

  bucket.budget = bucket.budgetCap
  bucket.lastTimeFull = currentTime

proc tryConsume*(bucket: TokenBucket, tokens: int, now = Moment.now()): bool =
  ## If `tokens` are available, consume them,
  ## Otherwhise, return false.

  if bucket.budget == bucket.budgetCap:
    bucket.lastTimeFull = now

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    return true

  bucket.update(now)

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    return true
  else:
    return false

proc replenish*(bucket: TokenBucket, tokens: int, now = Moment.now()) =
  ## Add `tokens` to the budget (capped to the bucket capacity)
  bucket.budget += tokens
  bucket.update(now)

proc new*(T: type[TokenBucket], budgetCap: int, fillDuration: Duration = 1.seconds): T =
  ## Create a TokenBucket
  T(
    budget: budgetCap,
    budgetCap: budgetCap,
    fillDuration: fillDuration,
    lastUpdate: Moment.now(),
    lastTimeFull: Moment.now(),
  )
