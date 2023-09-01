when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronos,
  chronicles
import
  ../../../waku_relay,
  ../../../waku_core,
  ../../message_cache

export message_cache

##### Message handler

proc messageHandler*(cache: MessageCache[string]): WakuRelayHandler =

  let handler = proc(pubsubTopic: string, msg: WakuMessage): Future[void] {.async, closure.} =
    cache.addMessage(PubSubTopic(pubsubTopic), msg)

  handler

proc autoMessageHandler*(cache: MessageCache[string]): WakuRelayHandler =

  let handler = proc(pubsubTopic: string, msg: WakuMessage): Future[void] {.async, closure.} =
    if cache.isSubscribed(msg.contentTopic):
      cache.addMessage(msg.contentTopic, msg)

  handler