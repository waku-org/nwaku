when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronos,
  chronicles
import
  ../waku_relay,
  ../waku_core,
  ./message_cache

##### Message handler

proc messageCacheHandler*(cache: MessageCache[string]): WakuRelayHandler =
  return proc(pubsubTopic: string, msg: WakuMessage): Future[void] {.async, closure.} =
    cache.addMessage(PubSubTopic(pubsubTopic), msg)

proc autoMessageCacheHandler*(cache: MessageCache[string]): WakuRelayHandler =
  return proc(pubsubTopic: string, msg: WakuMessage): Future[void] {.async, closure.} =
    if cache.isSubscribed(msg.contentTopic):
      cache.addMessage(msg.contentTopic, msg)