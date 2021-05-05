{.used.}

import
  std/[unittest, options, tables, sets],
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

    var msgs = @[
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic, version: uint32(0)),
      WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic, version: uint32(1)),
      WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: topic, version: high(uint32)),
    ]

    defer: store.close()

    for msg in msgs:
      let output = store.put(computeIndex(msg), msg, pubsubTopic)
      check output.isOk

    var v0Flag, v1Flag, vMaxFlag: bool = false
    var responseCount = 0
    proc data(timestamp: uint64, msg: WakuMessage, psTopic: string) =
      responseCount += 1
      check msg in msgs
      check psTopic == pubsubTopic
      # check the correct retrieval of versions
      if msg.version == uint32(0): v0Flag = true
      if msg.version == uint32(1): v1Flag = true
      # high(uint32) is the largest value that fits in uint32, this is to make sure there is no overflow in the storage
      if msg.version == high(uint32): vMaxFlag = true


    let res = store.getAll(data)
    
    check:
      res.isErr == false
      responseCount == 3
      v0Flag == true
      v1Flag == true
      vMaxFlag == true


