{.push raises: [Defect].}

import
  std/[tables, sequtils],
  stew/results,
  chronicles,
  chronos,
  libp2p/protocols/pubsub
import
  ../protocol/waku_message

logScope: topics = "message_cache"

const DefaultMessageCacheCapacity*: uint = 30 # Max number of messages cached per topic @TODO make this configurable


type MessageCacheResult*[T] = Result[T, cstring]

type MessageCache*[K] = ref object
  capacity: uint
  table: Table[K, seq[WakuMessage]]

func init*[K](T: type MessageCache[K], capacity=DefaultMessageCacheCapacity): T =
  MessageCache[K](
    capacity: capacity,
    table: initTable[K, seq[WakuMessage]]() 
  )


proc isSubscribed*[K](t: MessageCache[K], topic: K): bool =
  t.table.hasKey(topic)

proc subscribe*[K](t: MessageCache[K], topic: K) =
  if t.isSubscribed(topic):
    return
  t.table[topic] = @[]

proc unsubscribe*[K](t: MessageCache[K], topic: K) = 
  if not t.isSubscribed(topic):
    return
  t.table.del(topic)


proc addMessage*[K](t: MessageCache, topic: K, msg: WakuMessage) =
  if not t.isSubscribed(topic):
    return

  # Make a copy of msgs for this topic to modify
  var messages = t.table.getOrDefault(topic, @[])

  if messages.len >= t.capacity.int:
    debug "Topic cache capacity reached", topic=topic
    # Message cache on this topic exceeds maximum. Delete oldest.
    # TODO: this may become a bottle neck if called as the norm rather than 
    #  exception when adding messages. Performance profile needed.
    messages.delete(0,0)
  
  messages.add(msg)

  # Replace indexed entry with copy
  t.table[topic] = messages

proc clearMessages*[K](t: MessageCache[K], topic: K) =
  if not t.isSubscribed(topic):
    return
  t.table[topic] = @[]

proc getMessages*[K](t: MessageCache[K], topic: K, clear=false): MessageCacheResult[seq[WakuMessage]] =
  if not t.isSubscribed(topic):
    return err("Not subscribed to topic")

  let messages = t.table.getOrDefault(topic, @[])
  if clear:
    t.clearMessages(topic)

  ok(messages)
