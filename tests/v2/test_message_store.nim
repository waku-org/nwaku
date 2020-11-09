
import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  ../../waku/node/v2/[waku_types, message_store],
  ../test_helpers, ./utils

suite "Message Store":
  test "set and get works":
    let 
      store = MessageStore.init("", "test", inMemory = true)[]
      topic = ContentTopic(1)
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic)

    defer: store.close()

    discard store.put(msg1)
    discard store.put(msg2)

    var msgs = newSeq[WakuMessage]()
    proc data(msg: WakuMessage) =
      msgs.add(msg)
    
    let res = store.get(@[topic], data)
    
    check:
      res.isErr == false
      msgs.len == 2
      ((msgs[0] == msg1 and msgs[1] == msg2) or (msgs[0] == msg2 and msgs[1] == msg1))
