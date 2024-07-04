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
import ../../waku/common/ratelimit/tokenbucket

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
