## Waku Cache
##
## Manage content and pubsub topic subscriptions.
## When subscribing to a content topic the shard should not
## be manually unsubscribed from and vice versa.
## 
## Also contains a cache of messages for each topics.
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
   std/[sequtils, strutils, options, sets],
   stew/results,
   stew/shims/net,
   chronos,
   chronicles,
   metrics,
   libp2p/multiaddress,
   eth/keys as eth_keys,
   eth/p2p/discoveryv5/node,
   eth/p2p/discoveryv5/protocol
import
   ./node/peer_manager/peer_manager,
   ./node/message_cache,
   ./waku_core,
   ./waku_enr

type
  WakuCache* = ref object
    # Input
    rawSubscriptionQueue: AsyncEventQueue[SubscriptionEvent]
    messageQueue: AsyncEventQueue[(PubsubTopic, WakuMessage)]

    # State
    started: bool
    subscriptions: Table[PubsubTopic, tuple[manual: bool, count: int]]
    messageCache: MessageCache[string]

    # Output
    filteredSubscriptionQueue: AsyncEventQueue[(SubscriptionKind, PubsubTopic)]

proc new*(T: type WakuCache,
  rawTopicQueue: AsyncEventQueue[SubscriptionEvent],
  filteredTopicQueue: AsyncEventQueue[PubsubTopic],
  messageQueue: AsyncEventQueue[(PubsubTopic, WakuMessage)],
  cache: MessageCache[string]): T =

  let subscriptions = initTable[PubsubTopic, (bool, int)]

  return WakuCache (
    rawSubscriptionQueue: rawTopicQueue,
    subscriptions: subscriptions,
    filteredSubscriptionQueue: filteredTopicQueue,
    messageQueue: messageQueue,
    messageCache: cache,
  )

proc batchPubsubSubscribe(wc: WakuCache, batch: seq[PubsubTopic]) =
  for topic in batch:
    if wc.messageCache.isSubscribed(topic):
      continue

    wc.messageCache.subscribe(topic)

    if wc.subscriptions.hasKeyOrPut(topic, (true, 0)):
      wc.subscriptions.mgetOrPut(topic, (true, 0)).manual = true
    else:
      wc.filteredSubscriptionQueue.emit((PubsubSub, topic))

proc batchPubsubUnsubscribe(wc: WakuCache, batch: seq[PubsubTopic]) =
  for topic in batch:
    if not wc.messageCache.isSubscribed(topic):
      continue

    wc.messageCache.unsubscribe(topic)

    let value = wc.subscriptions.getOrDefault(topic)
    if value.count == 0 and value.manual:
      wc.subscriptions.del(topic)
      wc.filteredSubscriptionQueue.emit((PubsubUnsub, topic))
      continue

    wc.subscriptions.mgetOrPut(topic, (false, 0)).manual = false

proc batchContentSubscribe(wc: WakuCache, batch: seq[ContentTopic]) =
  for topic in batch:
    if wc.messageCache.isSubscribed(topic):
      continue

    wc.messageCache.subscribe(topic)

    let parsedTopicRes = NsContentTopic.parse(topic)
    let parsedTopic =
      if parsedTopicRes.isErr():
        error "Cannot parse content topic", error=parsedTopicRes.error
        continue
      else: parsedTopicRes.get()

    let pubsubRes = getShard(parsedTopic)
    let pubsub = 
      if pubsubRes.isErr():
        error "Cannot get shard", error=pubsubRes.error
        continue
      else: $pubsubRes.get()

    if wc.subscriptions.hasKeyOrPut(pubsub, (false, 1)):
      wc.subscriptions.mgetOrPut(pubsub, (false, 0)).count += 1
    else:
      wc.filteredSubscriptionQueue.emit((PubsubSub, pubsub))
    
proc batchContentUnsubscribe(wc: WakuCache, batch: seq[ContentTopic]) =
  for topic in batch:
    if not wc.messageCache.isSubscribed(topic):
      continue

    wc.messageCache.unsubscribe(topic)

    let parsedTopicRes = NsContentTopic.parse(topic)
    let parsedTopic =
      if parsedTopicRes.isErr():
        error "Cannot parse content topic", error=parsedTopicRes.error
        continue
      else: parsedTopicRes.get()

    let pubsubRes = getShard(parsedTopic)
    let pubsub = 
      if pubsubRes.isErr():
        error "Cannot get shard", error=pubsubRes.error
        continue
      else: $pubsubRes.get()
    
    let value = wc.subscriptions.mgetOrPut(pubsub, (false, 0))

    if value.count == 1 and not value.manual:
      wc.subscriptions.del(pubsub)
      wc.filteredSubscriptionQueue.emit((PubsubUnsub, pubsub))
      continue

    wc.subscriptions.mgetOrPut(pubsub, (false, 0)).count -= 1
      
proc topicFilteringLoop(wc: WakuCache) {.async.} =
  let key = wc.rawSubscriptionQueue.register()
  
  while wc.started:
    let events = await wc.rawSubscriptionQueue.waitEvents(key)

    # Since events arrive in any order we have to filter.
    let pubsubSubs = events.filterIt(it.kind == PubsubSub).mapIt(it.pubsubSub)
    let pubsubUnsubs = events.filterIt(it.kind == PubsubUnsub).mapIt(it.pubsubUnsub)
    let contentSubs = events.filterIt(it.kind == ContentSub).mapIt(it.contentSub)
    let contentUnsubs = events.filterIt(it.kind == ContentUnsub).mapIt(it.contentUnsub)

    wc.batchPubsubSubscribe(pubsubSubs)
    wc.batchPubsubUnsubscribe(pubsubUnsubs)
    wc.batchContentSubscribe(contentSubs)
    wc.batchContentUnsubscribe(contentUnsubs)

  wc.rawSubscriptionQueue.unregister(key)

proc messageCachingLoop(wc: WakuCache) {.async.} =
  let key = wc.messageQueue.register()

  while wc.started:
    let events = await wc.messageQueue.waitEvents(key)

    for (pubsubTopic, msg) in events:
      if wc.messageCache.isSubscribed(pubsubTopic):
        wc.messageCache.addMessage(pubsubTopic, msg)
      
      if wc.messageCache.isSubscribed(msg.contentTopic):
        wc.messageCache.addMessage(msg.contentTopic, msg)

  wc.messageQueue.unregister(key)

proc start*(wc: WakuCache) {.async.} =
  wc.started = true

  asyncSpawn wc.topicFilteringLoop()
  asyncSpawn wc.messageCachingLoop()

proc stop*(wc: WakuCache) {.async.} = wc.started = false