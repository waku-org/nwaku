
import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  ../../waku/v2/node/message_store,
  ../../waku/v2/protocol/waku_store/waku_store,
  ./utils,
  ../../waku/v2/waku_types,
  ../../waku/v2/node/sqlite

suite "Message Store":
  test "set and get works":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = MessageStore.init(database)[]
      topic = ContentTopic(1)

    var msgs = @[
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic),
      WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic),
      WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: topic),
    ]

    defer: store.close()

    for msg in msgs:
      discard store.put(computeIndex(msg), msg)

    var responseCount = 0
    proc data(timestamp: uint64, msg: WakuMessage) =
      responseCount += 1
      check msg in msgs
    
    let res = store.getAll(data)
    
    check:
      res.isErr == false
      responseCount == 3
