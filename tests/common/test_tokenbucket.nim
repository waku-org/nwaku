#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.used.}

import testutils/unittests
import chronos
import ../../waku/common/rate_limit/token_bucket

suite "Token Bucket":
  test "TokenBucket Sync test - strict":
    var bucket = TokenBucket.newStrict(1000, 1.milliseconds)
    let
      start = Moment.now()
      fullTime = start + 1.milliseconds
    check:
      bucket.tryConsume(800, start) == true
      bucket.tryConsume(200, start) == true
      # Out of budget
      bucket.tryConsume(100, start) == false
      bucket.tryConsume(800, fullTime) == true
      bucket.tryConsume(200, fullTime) == true
      # Out of budget
      bucket.tryConsume(100, fullTime) == false

  test "TokenBucket Sync test - compensating":
    var bucket = TokenBucket.new(1000, 1.milliseconds)
    let
      start = Moment.now()
      fullTime = start + 1.milliseconds
    check:
      bucket.tryConsume(800, start) == true
      bucket.tryConsume(200, start) == true
      # Out of budget
      bucket.tryConsume(100, start) == false
      bucket.tryConsume(800, fullTime) == true
      bucket.tryConsume(200, fullTime) == true
      # Due not using the bucket for a full period the compensation will satisfy this request
      bucket.tryConsume(100, fullTime) == true

  test "TokenBucket Max compensation":
    var bucket = TokenBucket.new(1000, 1.minutes)
    var reqTime = Moment.now()

    check bucket.tryConsume(1000, reqTime)
    check bucket.tryConsume(1, reqTime) == false
    reqTime += 1.minutes
    check bucket.tryConsume(500, reqTime) == true
    reqTime += 1.minutes
    check bucket.tryConsume(1000, reqTime) == true
    reqTime += 10.seconds
    # max compensation is 25% so try to consume 250 more
    check bucket.tryConsume(250, reqTime) == true
    reqTime += 49.seconds
    # out of budget within the same period
    check bucket.tryConsume(1, reqTime) == false

  test "TokenBucket Short replenish":
    var bucket = TokenBucket.new(15000, 1.milliseconds)
    let start = Moment.now()
    check bucket.tryConsume(15000, start)
    check bucket.tryConsume(1, start) == false

    check bucket.tryConsume(15000, start + 1.milliseconds) == true

  test "TokenBucket getAvailableCapacity strict":
    var bucket = TokenBucket.new(1000, 1.minutes, ReplenishMode.Strict)
    var reqTime = Moment.now()

    # Test full bucket capacity ratio
    check bucket.getAvailableCapacity(reqTime) == (1000, 1000)

    # Consume some tokens and check ratio
    reqTime += 1.seconds
    check bucket.tryConsume(400, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (600, 1000)

    # Consume more tokens
    reqTime += 1.seconds
    check bucket.tryConsume(300, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (300, 1000)

    # Test when period has elapsed (should return 1.0)
    reqTime += 1.minutes
    check bucket.getAvailableCapacity(reqTime) == (1000, 1000)

    # Test with empty bucket
    check bucket.tryConsume(1000, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (0, 1000)

  test "TokenBucket getAvailableCapacity compensating":
    var bucket = TokenBucket.new(1000, 1.minutes, ReplenishMode.Compensating)
    var reqTime = Moment.now()

    # Test full bucket capacity
    check bucket.getAvailableCapacity(reqTime) == (1000, 1000)

    # Consume some tokens and check available capacity
    reqTime += 1.seconds
    check bucket.tryConsume(400, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (600, 1000)

    # Consume more tokens
    reqTime += 1.seconds
    check bucket.tryConsume(300, reqTime) == true
    check bucket.getAvailableCapacity(reqTime) == (300, 1000)

    # Test compensation when period has elapsed - should get compensation for unused capacity
    # We used 700 tokens out of 1000 in 2 periods, so average usage was 35% per period
    # Compensation should be added for the unused 65% capacity (up to 25% max)
    reqTime += 1.minutes
    let (availableBudget, maxCap) = bucket.getAvailableCapacity(reqTime)
    check maxCap == 1000
    check availableBudget >= 1000  # Should have compensation
    check availableBudget <= 1250  # But limited to 25% max compensation

    # Test with minimal usage - less consumption means less compensation
    bucket = TokenBucket.new(1000, 1.minutes, ReplenishMode.Compensating)
    reqTime = Moment.now()
    check bucket.tryConsume(50, reqTime) == true  # Use only 5% of capacity (950 remaining)
    
    # Move to next period - compensation based on remaining budget
    # UsageAverage = 950/1000/1.0 = 0.95, so compensation = (1.0-0.95)*1000 = 50
    reqTime += 1.minutes
    let (compensatedBudget, _) = bucket.getAvailableCapacity(reqTime)
    check compensatedBudget == 1050  # 1000 + 50 compensation

    # Test with full usage - maximum compensation due to zero remaining budget
    bucket = TokenBucket.new(1000, 1.minutes, ReplenishMode.Compensating)
    reqTime = Moment.now()
    check bucket.tryConsume(1000, reqTime) == true  # Use full capacity (0 remaining)
    
    # Move to next period - maximum compensation since usage average is 0
    # UsageAverage = 0/1000/1.0 = 0.0, so compensation = (1.0-0.0)*1000 = 1000, capped at 250
    reqTime += 1.minutes
    let (maxCompensationBudget, _) = bucket.getAvailableCapacity(reqTime)
    check maxCompensationBudget == 1250  # 1000 + 250 max compensation

