{.used.}

import
  std/random, 
  testutils/unittests,
  ../../waku/v2/utils/time

procSuite "Time utility":
  
  # We initialize the RNG in std/random
  randomize()

  test "Timestamp over- and under-flows":

    let
      t1 = Timestamp.low   # = -9223372036854775808
      t2 = Timestamp.high  # =  9223372036854775807

    echo t1
    
    check:
      t1 + t1 == Timestamp.low
      t2 + t2 == Timestamp.high
      -t1 + t2 == Timestamp.high
      t1 - t2 == Timestamp.low
      # Note that -Timestamp.low overflows, so sign distributivity is not always preserved
      t1 + t2 == Timestamp(-1)
      -(t1 + t2) == Timestamp(1)
      -t1 - t2 == Timestamp(0)
      t2 + t2 + t2 + Timestamp(rand(int.high)) == Timestamp.high
      t1 + t1 + t1 - Timestamp(rand(int.high)) == Timestamp.low

