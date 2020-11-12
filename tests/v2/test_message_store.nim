
import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  ../../waku/node/v2/[waku_types, message_store],
  ../test_helpers, ./utils

suite "Message Store":
  test "set and get works":
    let 
      store = MessageStore.init("", inMemory = true)[]
      topic = ContentTopic(1)
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: topic)

    defer: store.close()

    discard store.put(msg1)
    discard store.put(msg2)
    discard store.put(msg3)

    var msgs = newSeq[WakuMessage]()
    proc data(timestamp: uint64, msg: WakuMessage) =
      msgs.add(msg)
    
    let res = store.get(@[topic], PagingInfo(direction: BACKWARD, pageSize: 2), data)
    
    check:
      res.isErr == false
      msgs.len == 2
      msgs[0] == msg1
      msgs[1] == msg3
