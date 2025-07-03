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
import std/math
import ../../waku/common/rate_limit/token_bucket

# Helper function for approximate float equality
proc equals(a, b: float, tolerance: float = 1e-6): bool =
  abs(a - b) <= tolerance

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

  test "TokenBucket getAvailableCapacityRatio":
    var bucket = TokenBucket.new(1000, 1.minutes, ReplenishMode.Strict)
    var reqTime = Moment.now()

    # Test full bucket capacity ratio
    check equals(bucket.getAvailableCapacityRatio(reqTime), 1.0) # 1000/1000 = 1.0

    # Consume some tokens and check ratio
    reqTime += 1.seconds
    check bucket.tryConsume(400, reqTime) == true
    check equals(bucket.getAvailableCapacityRatio(reqTime), 0.6) # 600/1000 = 0.6

    # Consume more tokens
    reqTime += 1.seconds
    check bucket.tryConsume(300, reqTime) == true
    check equals(bucket.getAvailableCapacityRatio(reqTime), 0.3) # 300/1000 = 0.3

    # Test when period has elapsed (should return 1.0)
    reqTime += 1.minutes
    check equals(bucket.getAvailableCapacityRatio(reqTime), 1.0) # 1000/1000 = 1.0

    # Test with empty bucket
    check bucket.tryConsume(1000, reqTime) == true
    check equals(bucket.getAvailableCapacityRatio(reqTime), 0.0) # 0/1000 = 0.0
