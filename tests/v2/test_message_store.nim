{.used.}

import
  std/[unittest, options, tables, sets, times],
  chronos, chronicles,
  ../../waku/v2/node/storage/message/waku_message_store,
  ../../waku/v2/protocol/waku_store/waku_store,
  ./utils

suite "Message Store":
  test "set and get works":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      topic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic =  "/waku/2/default-waku/proto"

      t1 = epochTime()
      t2 = epochTime()
      t3 = high(float64)
    var msgs = @[
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic, version: uint32(0), timestamp: t1),
      WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic, version: uint32(1), timestamp: t2),
      WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: topic, version: high(uint32), timestamp: t3),
    ]

    defer: store.close()

    for msg in msgs:
      let output = store.put(computeIndex(msg), msg, pubsubTopic)
      check output.isOk

    var v0Flag, v1Flag, vMaxFlag: bool = false
    var t1Flag, t2Flag, t3Flag: bool = false
    var responseCount = 0
    proc data(timestamp: uint64, msg: WakuMessage, psTopic: string) =
      echo $msg
      responseCount += 1
      check msg in msgs
      check psTopic == pubsubTopic

      # check the correct retrieval of versions
      if msg.version == uint32(0): v0Flag = true
      if msg.version == uint32(1): v1Flag = true
      # high(uint32) is the largest value that fits in uint32, this is to make sure there is no overflow in the storage
      if msg.version == high(uint32): vMaxFlag = true

      # check correct retrieval of timestamps
      if msg.timestamp == t1: t1Flag = true
      if msg.timestamp == t2: t2Flag = true
      if msg.timestamp == t3: t3Flag = true


    let res = store.getAll(data)
    
    check:
      res.isErr == false
      responseCount == 3
      # await allFutures(times)
      t1Flag == true
      t2Flag == true
      t3Flag == true

      v0Flag == true
      v1Flag == true
      vMaxFlag == true


