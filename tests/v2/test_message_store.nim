
import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  ../../waku/node/v2/[waku_types, message_store],
  ../test_helpers, ./utils

suite "Message Store":
  test "set and get works":
    let 
      store = MessageStore.init("/tmp/", "db", inMemory = true).value
      topic = ContentTopic(1)
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      # msg2 = WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic)

    discard store.put(msg1)
    # discard store.put(msg2)

    proc data(msg: WakuMessage) =
      info "fuck", msg=msg
      check:
        msg == msg1
    # @TODO: WE NEED TO FIGURE OUT HOW TO FUCKING RETURN MULTIPLE ROWS AND WAIT.
    
    let res = store.get(@[topic], data)
    
    check:
      res.value == true
      res.isErr == false

    # check:
    #   res.value.len == 2