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
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic, version: uint32(4294967295)),
      WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic, version: uint32(4294967295)),
      WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: topic, version: uint32(4294967295)),
    ]

    defer: store.close()
    echo "here we are"
    for msg in msgs:
      let output = store.put(computeIndex(msg), msg, pubsubTopic)
      check output.isOk

    var responseCount = 0
    proc data(timestamp: uint64, msg: WakuMessage, psTopic: string) =
      responseCount += 1
      check msg in msgs
      check psTopic == pubsubTopic
      check msg.version == uint32(4294967295)
    
    let res = store.getAll(data)
    
    check:
      res.isErr == false
      responseCount == 3
