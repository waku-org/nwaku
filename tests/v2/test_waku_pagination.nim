{.used.}
import
  std/unittest,
  ../../waku/node/v2/waku_types,
  ../test_helpers

procSuite "pagination":
  test "computeIndex: empty contentTopic test":
    let
      wm = WakuMessage(payload: @[byte 1, 2, 3])
      index = wm.computeIndex()
    check:
      # the fields of the index should be non-empty
      len(index.digest.data) != 0
      len(index.digest.data) == 32 # sha2 output length in bytes
      index.receivedTime != 0 # the timestamp should be a non-zero value

  test "computeIndex: identical WakuMessages test":
    let
      wm = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic(1))
      index1 = wm.computeIndex()
      wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic(1))
      index2 = wm2.computeIndex()

    check:
      # the digests of two identical WakuMessages must be the same
      index1.digest == index2.digest

