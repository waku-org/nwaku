when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos

## This is an extract from chronos/ratelimit.nim due to the found bug in the original implementation.
## Unfortunately that bug cannot be solved without harm the original features of TokenBucket class.
## So, this current shortcut is used to enable move ahead with nwaku rate limiter implementation.
type TokenBucket* = ref object
  budget*: int ## Current number of tokens in the bucket
  budgetCap: int ## Bucket capacity
  lastTimeFull: Moment
    ## This timer measures the proper periodizaiton of the bucket refilling
  fillDuration: Duration ## Refill period

## Update will take place if bucket is empty and trying to consume tokens.
## It checks if the bucket can be replenished as refill duration is passed or not.
proc update(bucket: TokenBucket, currentTime: Moment) =
  if bucket.fillDuration == default(Duration):
    bucket.budget = min(bucket.budgetCap, bucket.budget)
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
    lastTimeFull: Moment.now(),
  )
