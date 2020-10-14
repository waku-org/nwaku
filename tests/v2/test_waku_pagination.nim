import
    std/unittest,
    ../../waku/node/v2/waku_types,
    ../test_helpers

procSuite "pagination":

    test "computeIndex should handle empty contentTopic":
        let wm = WakuMessage(payload: @[byte 1, 2, 3])
        let index=wm.computeIndex()
        check:
            # the output index should be non-empty
            index.digest.len != 0
            index.receivedTime.len != 0
        

    test "computeIndex must be deterministic":
        let wm = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic2")
        let index1=wm.computeIndex()

        let wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic2")
        let index2=wm2.computeIndex()
        check:
            # the index of two identical WakuMessages must be the same
            index1==index2