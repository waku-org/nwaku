when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronos,
  chronicles
import
  ../../../protocol/waku_relay,
  ../../../protocol/waku_message,
  ../../message_cache

export message_cache


##### TopicCache

type TopicCacheResult*[T] = MessageCacheResult[T]

type TopicCache* = MessageCache[PubSubTopic]


##### Message handler

type TopicCacheMessageHandler* = SubscriptionHandler

proc messageHandler*(cache: TopicCache): TopicCacheMessageHandler =

  let handler = proc(pubsubTopic: string, msg: WakuMessage): Future[void] {.async, closure.} =
    cache.addMessage(PubSubTopic(pubsubTopic), msg)

  handler
