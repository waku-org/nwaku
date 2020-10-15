import
    std/unittest, times,
    ../../waku/node/v2/waku_types,
    ../test_helpers,
    nimcrypto/sha2

procSuite "pagination":

    test "computeIndex empty contentTopic test":
        let wm = WakuMessage(payload: @[byte 1, 2, 3])
        let index=wm.computeIndex()
        check:
            # the fields of the index should be non-empty
            index.digest.len != 0
            index.receivedTime!=0 
        
    test "computeIndex identical WakuMessages test":
        let wm = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic2")
        let index1=wm.computeIndex()

        let wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: "topic2")
        let index2=wm2.computeIndex()
        check:
            # the digests of two identical WakuMessages must be the same
            index1.digest==index2.digest