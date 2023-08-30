## Waku Cache
##
## Manage content and pubsub topic subscriptions.
## 
## When unsubscribing from a content topic the shard should not
## be unsubscribed if previously other shard use it.
## 
## This also apply when shards are subscribed to and content topic are used.
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
    topicSubscriptions: AsyncEventQueue[SubscriptionEvent]
    messagesReceiver: AsyncEventQueue[(PubsubTopic, WakuMessage)]

    # State
    started: bool
    subscriptions: Table[PubsubTopic, tuple[manual: bool, count: int]]
    messageCache*: MessageCache[string]
    messagesListener: Option[Future[void]]
    subscriptionsListener: Option[Future[void]]

    # Output
    pubsubTopicSubscriptions: AsyncEventQueue[(SubscriptionKind, PubsubTopic)]

proc new*(T: type WakuCache,
  topicSubscriptions: AsyncEventQueue[SubscriptionEvent],
  pubsubTopicSubscriptions: AsyncEventQueue[PubsubTopic],
  messagesReceiver: AsyncEventQueue[(PubsubTopic, WakuMessage)],
  cache: MessageCache[string]
  ): T =

  let subscriptions = initTable[PubsubTopic, (bool, int)]

  return WakuCache (
    topicSubscriptions: topicSubscriptions,
    subscriptions: subscriptions,
    pubsubTopicSubscriptions: pubsubTopicSubscriptions,
    messagesReceiver: messagesReceiver,
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
      wc.pubsubTopicSubscriptions.emit((PubsubSub, topic))

proc batchPubsubUnsubscribe(wc: WakuCache, batch: seq[PubsubTopic]) =
  for topic in batch:
    if not wc.messageCache.isSubscribed(topic):
      continue

    wc.messageCache.unsubscribe(topic)

    let value = wc.subscriptions.getOrDefault(topic)
    if value.count == 0 and value.manual:
      wc.subscriptions.del(topic)
      wc.pubsubTopicSubscriptions.emit((PubsubUnsub, topic))
      continue

    wc.subscriptions.mgetOrPut(topic, (false, 0)).manual = false

proc batchContentSubscribe(wc: WakuCache, batch: seq[ContentTopic]) =
  for topic in batch:
    if wc.messageCache.isSubscribed(topic):
      continue

    wc.messageCache.subscribe(topic)

    let pubsubRes = getShard(topic)
    if pubsubRes.isErr():
      error "Cannot parse content topic", error=pubsubRes.error
      continue
    let pubsub = pubsubRes.get()

    if wc.subscriptions.hasKeyOrPut(pubsub, (false, 1)):
      wc.subscriptions.mgetOrPut(pubsub, (false, 0)).count += 1
    else:
      wc.pubsubTopicSubscriptions.emit((PubsubSub, pubsub))
    
proc batchContentUnsubscribe(wc: WakuCache, batch: seq[ContentTopic]) =
  for topic in batch:
    if not wc.messageCache.isSubscribed(topic):
      continue

    wc.messageCache.unsubscribe(topic)

    let pubsubRes = getShard(topic)
    if pubsubRes.isErr():
      error "Cannot get shard", error=pubsubRes.error
      continue
    let pubsub = pubsubRes.get()

    let value = wc.subscriptions.mgetOrPut(pubsub, (false, 0))

    if value.count == 1 and not value.manual:
      wc.subscriptions.del(pubsub)
      wc.pubsubTopicSubscriptions.emit((PubsubUnsub, pubsub))
      continue

    wc.subscriptions.mgetOrPut(pubsub, (false, 0)).count -= 1
      
proc topicFilteringLoop(wc: WakuCache) {.async.} =
  let key = wc.topicSubscriptions.register()
  
  while wc.started:
    let events = await wc.topicSubscriptions.waitEvents(key)

    # Since events arrive in any order we have to filter.
    let pubsubSubs = events.filterIt(it.kind == PubsubSub).mapIt(it.pubsubSub)
    let pubsubUnsubs = events.filterIt(it.kind == PubsubUnsub).mapIt(it.pubsubUnsub)
    let contentSubs = events.filterIt(it.kind == ContentSub).mapIt(it.contentSub)
    let contentUnsubs = events.filterIt(it.kind == ContentUnsub).mapIt(it.contentUnsub)

    wc.batchPubsubSubscribe(pubsubSubs)
    wc.batchPubsubUnsubscribe(pubsubUnsubs)
    wc.batchContentSubscribe(contentSubs)
    wc.batchContentUnsubscribe(contentUnsubs)

  wc.topicSubscriptions.unregister(key)

proc messageCachingLoop(wc: WakuCache) {.async.} =
  let key = wc.messagesReceiver.register()

  while wc.started:
    let events = await wc.messagesReceiver.waitEvents(key)

    for (pubsubTopic, msg) in events:
      if wc.messageCache.isSubscribed(pubsubTopic):
        wc.messageCache.addMessage(pubsubTopic, msg)
      
      if wc.messageCache.isSubscribed(msg.contentTopic):
        wc.messageCache.addMessage(msg.contentTopic, msg)

  wc.messagesReceiver.unregister(key)

proc start*(wc: WakuCache) {.async.} =
  wc.started = true

  wc.subscriptionsListener = some(wc.topicFilteringLoop())
  wc.messagesListener = some(wc.messageCachingLoop())

proc stop*(wc: WakuCache) {.async.} =
  wc.started = false

  if wc.subscriptionsListener.isSome():
    await cancelAndWait(wc.subscriptionsListener.get())

  if wc.messagesListener.isSome():
    await cancelAndWait(wc.messagesListener.get())
