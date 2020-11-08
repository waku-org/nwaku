
import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  ../../waku/node/v2/[waku_types, message_store],
  ../test_helpers, ./utils

suite "Message Store":
  test "set and get works":
    let 
      store = MessageStore.init("", "db", inMemory =true).value
      topic = ContentTopic(1)
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)

    discard store.put(msg)

    # @TODO: WE NEED TO FIGURE OUT HOW TO FUCKING RETURN MULTIPLE ROWS AND WAIT.

    proc handler(val: WakuMessage) {.closure.} =
      check:
        msg == val

    discard store.get(@[topic], handler)
