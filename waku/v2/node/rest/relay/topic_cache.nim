{.push raises: [Defect].}

import
  std/[tables, sequtils],
  stew/results,
  chronicles,
  chronos,
  libp2p/protocols/pubsub
import
  ../../../protocol/waku_message

logScope: topics = "rest_api_relay_topiccache"

const DEFAULT_TOPICCACHE_CAPACITY* = 30 # Max number of messages cached per topic @TODO make this configurable


type PubSubTopicString = string 

type TopicCacheResult*[T] = Result[T, cstring]

type TopicCacheMessageHandler* = Topichandler


type TopicCacheConfig* = object
  capacity*: int

proc default*(T: type TopicCacheConfig): T =
  TopicCacheConfig(
    capacity: DEFAULT_TOPICCACHE_CAPACITY
  )


type TopicCache* = ref object
  conf: TopicCacheConfig
  table: Table[PubSubTopicString, seq[WakuMessage]]

func init*(T: type TopicCache, conf=TopicCacheConfig.default()): T =
  TopicCache(
    conf: conf,
    table: initTable[PubSubTopicString, seq[WakuMessage]]() 
  )


proc isSubscribed*(t: TopicCache, topic: PubSubTopicString): bool =
  t.table.hasKey(topic)

proc subscribe*(t: TopicCache, topic: PubSubTopicString) =
  if t.isSubscribed(topic):
    return
  t.table[topic] = @[]

proc unsubscribe*(t: TopicCache, topic: PubSubTopicString) = 
  if not t.isSubscribed(topic):
    return
  t.table.del(topic)


proc addMessage*(t: TopicCache, topic: PubSubTopicString, msg: WakuMessage) =
  if not t.isSubscribed(topic):
    return

  # Make a copy of msgs for this topic to modify
  var messages = t.table.getOrDefault(topic, @[])

  if messages.len >= t.conf.capacity:
    debug "Topic cache capacity reached", topic=topic
    # Message cache on this topic exceeds maximum. Delete oldest.
    # TODO: this may become a bottle neck if called as the norm rather than 
    #  exception when adding messages. Performance profile needed.
    messages.delete(0,0)
  
  messages.add(msg)

  # Replace indexed entry with copy
  t.table[topic] = messages

proc clearMessages*(t: TopicCache, topic: PubSubTopicString) =
  if not t.isSubscribed(topic):
    return
  t.table[topic] = @[]

proc getMessages*(t: TopicCache, topic: PubSubTopicString, clear=false): TopicCacheResult[seq[WakuMessage]] =
  if not t.isSubscribed(topic):
    return err("Not subscribed to topic")

  let messages = t.table.getOrDefault(topic, @[])
  if clear:
    t.clearMessages(topic)

  ok(messages)


proc messageHandler*(cache: TopicCache): TopicCacheMessageHandler =

  proc handler(topic: string, data: seq[byte]): Future[void] {.async, raises: [Defect].} =
    trace "Topic handler triggered", topic=topic

    # Add message to current cache
    let msg = WakuMessage.init(data)
    if msg.isErr():
      debug "WakuMessage received but failed to decode", msg=msg, topic=topic
      # TODO: handle message decode failure
      return

    trace "WakuMessage received", msg=msg, topic=topic
    cache.addMessage(PubSubTopicString(topic), msg.get())
  
  handler