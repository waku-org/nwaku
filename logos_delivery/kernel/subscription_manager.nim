import std/[sequtils, sets, tables], chronos, chronicles, metrics, results

import libp2p/[peerid, peerinfo]
import brokers/broker_context

import
  logos_delivery/kernel/[
    base/topics/content_topic,
    base/topics/pubsub_topic,
    base/enr/sharding,
    base/message,
    protocols/protocols,
    protocols/relay/protocol,
    archive/archive,
    protocols/store_sync/reconciliation,
    protocols/filter/client as filter_client,
    protocols/filter/protocol as filter_protocol,
    protocols/filter/edge_subscriptions,
    events/health_events,
    events/subscription_events,
    peer_manager/peer_manager,
  ]
import logos_delivery/kernel/[events/kernel_events]
{.push raises: [].}

declarePublicCounter logos_delivery_node_messages,
  "number of messages received", ["type"]

declarePublicHistogram logos_delivery_histogram_message_size,
  "message size histogram in kB",
  buckets = [
    0.0, 1.0, 3.0, 5.0, 15.0, 50.0, 75.0, 100.0, 125.0, 150.0, 500.0, 700.0, 1000.0, Inf
  ]

type
  SubscriptionKind* = enum
    ContentSub
    ContentUnsub
    PubsubSub
    PubsubUnsub

  SubscriptionEvent* = tuple[kind: SubscriptionKind, topic: string]

  ShardSubscription* = object
    contentTopics*: HashSet[ContentTopic]
    directShardSub*: bool
      ## shard subscribed directly (PubsubSub), independent of content-topic interest

type SubscriptionManager* = ref object of RootObj
  protocols*: Protocols
  peerManager*: PeerManager
  brokerCtx*: BrokerContext
  getAutoSharding*: proc(): Opt[Sharding] {.gcsafe, raises: [].}
    ## A callback because the node mounts auto-sharding after this is built.
  shards*: Table[PubsubTopic, ShardSubscription]
  extraListenShards*: seq[PubsubTopic]
    ## Shards every content topic is also subscribed on, receive-only.
    ## Deprecated: removed once Status's shard migration ends, see
    ## https://github.com/status-im/status-go/issues/7498.
  edgeFilter*: EdgeFilterSubscriptions
    ## The filter-client subscriptions of an edge node.

proc registerRelayHandler(
    self: SubscriptionManager, shard: PubsubTopic, appHandler: WakuRelayHandler = nil
): bool =
  ## Returns true iff we did a new (and only) subscription for this shard in GossipSub.
  let alreadySubscribed = self.protocols.relay.isSubscribed(shard)

  if not appHandler.isNil():
    if not alreadySubscribed or not self.protocols.legacyAppHandlers.hasKey(shard):
      self.protocols.legacyAppHandlers[shard] = appHandler
    else:
      debug "Legacy appHandler already exists for active shard, ignoring new handler",
        shard

  if alreadySubscribed:
    return false

  proc traceHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    let msgSizeKB = msg.payload.len / 1000

    logos_delivery_node_messages.inc(labelValues = ["relay"])
    logos_delivery_histogram_message_size.observe(msgSizeKB)

  proc filterHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if self.protocols.filter.isNil():
      return

    await self.protocols.filter.handleMessage(topic, msg)

  proc archiveHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if self.protocols.archive.isNil():
      return

    await self.protocols.archive.handleMessage(topic, msg)

  proc syncHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if self.protocols.storeReconciliation.isNil():
      return

    self.protocols.storeReconciliation.messageIngress(topic, msg)

  proc internalHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    MessageSeenEvent.emit(self.brokerCtx, topic, msg)

  let uniqueTopicHandler = proc(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    await traceHandler(topic, msg)
    await filterHandler(topic, msg)
    await archiveHandler(topic, msg)
    await syncHandler(topic, msg)
    await internalHandler(topic, msg)

    if self.protocols.legacyAppHandlers.hasKey(topic) and
        not self.protocols.legacyAppHandlers[topic].isNil():
      await self.protocols.legacyAppHandlers[topic](topic, msg)

  self.protocols.relay.subscribe(shard, uniqueTopicHandler)
  return true

proc unregisterRelayHandler(self: SubscriptionManager, shard: PubsubTopic): bool =
  ## Returns true iff we had a subscription for this shard in GossipSub and it was removed.
  if self.protocols.legacyAppHandlers.hasKey(shard):
    self.protocols.legacyAppHandlers.del(shard)

  if self.protocols.relay.isSubscribed(shard):
    self.protocols.relay.unsubscribe(shard)
    return true
  return false

proc doRelaySubscribe(
    self: SubscriptionManager, shard: PubsubTopic, appHandler: WakuRelayHandler = nil
): bool =
  ## Subscribes the node to a shard.
  ## Returns true if we actually subscribed (transitioned from unsubscribed to subscribed).
  ## Emit the shard subscription event if we actually subscribed.
  let installed = self.registerRelayHandler(shard, appHandler)
  if installed:
    ShardSubscribedEvent.emit(self.brokerCtx, ShardSubscribedEvent(topic: shard))
  return installed

proc doRelayUnsubscribe(self: SubscriptionManager, shard: PubsubTopic): bool =
  ## Unsubscribes the node from a shard.
  ## Returns true if we actually unsubscribed (transitioned from subscribed to unsubscribed).
  ## Emit the shard unsubscription event if we actually unsubscribed.
  let unsubscribed = self.unregisterRelayHandler(shard)
  if unsubscribed:
    ShardUnsubscribedEvent.emit(self.brokerCtx, ShardUnsubscribedEvent(topic: shard))
  return unsubscribed

proc desiredFilterTopics(
    self: SubscriptionManager
): Table[PubsubTopic, HashSet[ContentTopic]] =
  ## The content topics wanted on each shard; shards with none are left out.
  var desired = initTable[PubsubTopic, HashSet[ContentTopic]]()
  for shard, sub in self.shards.pairs:
    if sub.contentTopics.len > 0:
      desired[shard] = sub.contentTopics
  return desired

proc new*(
    T: type SubscriptionManager,
    protocols: Protocols,
    peerManager: PeerManager,
    brokerCtx: BrokerContext,
    getAutoSharding: proc(): Opt[Sharding] {.gcsafe, raises: [].},
): T =
  let manager = T(
    protocols: protocols,
    peerManager: peerManager,
    brokerCtx: brokerCtx,
    getAutoSharding: getAutoSharding,
    shards: initTable[PubsubTopic, ShardSubscription](),
  )
  manager.edgeFilter = EdgeFilterSubscriptions.new(
    peerManager,
    brokerCtx,
    proc(): WakuFilterClient {.gcsafe, raises: [].} =
      protocols.filterClient,
    proc(): Table[PubsubTopic, HashSet[ContentTopic]] {.gcsafe, raises: [].} =
      manager.desiredFilterTopics(),
  )
  return manager

proc edgeFilterPeerCount*(self: SubscriptionManager, shard: PubsubTopic): int =
  self.edgeFilter.peerCount(shard)

proc edgeFilterSubStates*(
    self: SubscriptionManager
): Table[PubsubTopic, EdgeFilterSubState] =
  self.edgeFilter.subStates

proc edgeFilterLoopInterval*(self: SubscriptionManager): Duration =
  self.edgeFilter.loopInterval

proc `edgeFilterLoopInterval=`*(self: SubscriptionManager, interval: Duration) =
  self.edgeFilter.loopInterval = interval

proc edgeFilterSubLoopDebounce*(self: SubscriptionManager): Duration =
  self.edgeFilter.subLoopDebounce

proc `edgeFilterSubLoopDebounce=`*(self: SubscriptionManager, debounce: Duration) =
  self.edgeFilter.subLoopDebounce = debounce

func wanted(entry: ShardSubscription): bool =
  ## True if the shard has content-topic interest or a direct subscription.
  return entry.contentTopics.len > 0 or entry.directShardSub

proc isContentSubscribed*(
    self: SubscriptionManager, shard: PubsubTopic, contentTopic: ContentTopic
): bool =
  self.shards.withValue(shard, sub):
    return contentTopic in sub.contentTopics
  return false

iterator subscribedContentTopics*(
    self: SubscriptionManager
): (PubsubTopic, HashSet[ContentTopic]) =
  ## Yields each shard with its non-empty content-topic set.
  for shard, sub in self.shards.pairs:
    if sub.contentTopics.len > 0:
      yield (shard, sub.contentTopics)

proc getShardForContentTopic(
    self: SubscriptionManager, topic: ContentTopic
): Result[PubsubTopic, string] =
  if self.getAutoSharding().isSome():
    let shardObj = ?self.getAutoSharding().get().getShard(topic)
    return ok($shardObj)

  return err("autosharding is not configured; pass an explicit shard")

proc subscribeShard*(
    self: SubscriptionManager, shard: PubsubTopic, handler: WakuRelayHandler = nil
): Result[void, string] =
  ## Subscribes to the shard directly and joins the relay mesh.
  var added = false
  self.shards.withValue(shard, entry):
    if not entry.directShardSub:
      entry.directShardSub = true
      added = true
  do:
    self.shards[shard] = ShardSubscription(
      contentTopics: initHashSet[ContentTopic](), directShardSub: true
    )
    added = true
  if added:
    self.edgeFilter.wake()
  if not isNil(self.protocols.relay):
    discard self.doRelaySubscribe(shard, handler)
  return ok()

proc unsubscribeShard*(
    self: SubscriptionManager, shard: PubsubTopic
): Result[void, string] =
  ## Drops the direct shard subscription; unsubscribes the mesh if no content topic wants it.
  var removed = false
  var shardEmpty = false
  self.shards.withValue(shard, entry):
    if entry.directShardSub:
      entry.directShardSub = false
      removed = true
      shardEmpty = not entry[].wanted()
  if removed:
    self.edgeFilter.wake()
    if shardEmpty:
      self.shards.del(shard)
      if not isNil(self.protocols.relay):
        discard self.doRelayUnsubscribe(shard)
  return ok()

proc subscribe*(
    self: SubscriptionManager,
    shard: PubsubTopic,
    contentTopic: ContentTopic,
    handler: WakuRelayHandler = nil,
): Result[void, string] =
  ## Adds content-topic interest on the shard and joins the relay mesh.
  var added = false
  self.shards.withValue(shard, entry):
    if contentTopic notin entry.contentTopics:
      entry.contentTopics.incl(contentTopic)
      added = true
  do:
    var entry = ShardSubscription(contentTopics: initHashSet[ContentTopic]())
    entry.contentTopics.incl(contentTopic)
    self.shards[shard] = entry
    added = true
  if added:
    self.edgeFilter.wake()
  if not isNil(self.protocols.relay):
    discard self.doRelaySubscribe(shard, handler)
  if added:
    ContentTopicSubscribedEvent.emit(self.brokerCtx, shard, contentTopic)
  return ok()

proc unsubscribe*(
    self: SubscriptionManager, shard: PubsubTopic, contentTopic: ContentTopic
): Result[void, string] =
  ## Drops content-topic interest on the shard; unsubscribes the mesh if nothing else wants it.
  var removed = false
  var shardEmpty = false
  self.shards.withValue(shard, entry):
    if contentTopic in entry.contentTopics:
      entry.contentTopics.excl(contentTopic)
      removed = true
      shardEmpty = not entry[].wanted()
  if removed:
    self.edgeFilter.wake()
    if shardEmpty:
      self.shards.del(shard)
      if not isNil(self.protocols.relay):
        discard self.doRelayUnsubscribe(shard)
    ContentTopicUnsubscribedEvent.emit(self.brokerCtx, shard, contentTopic)
  return ok()

proc hasContentTopic(
    self: SubscriptionManager, shard: PubsubTopic, contentTopic: ContentTopic
): bool =
  self.shards.withValue(shard, entry):
    return contentTopic in entry.contentTopics
  return false

proc topicShards(self: SubscriptionManager, shard: PubsubTopic): seq[PubsubTopic] =
  result = @[shard]
  for listenShard in self.extraListenShards:
    if listenShard != shard:
      result.add(listenShard)

proc subscribe*(self: SubscriptionManager, topic: ContentTopic): Result[void, string] =
  ## Subscribes to a content topic, resolving its shard via autosharding, and
  ## on every extra listen shard. On failure, drops the subscriptions it added.
  let shard = ?self.getShardForContentTopic(topic)
  var added: seq[PubsubTopic]
  for target in self.topicShards(shard):
    let isNew = not self.hasContentTopic(target, topic)
    self.subscribe(target, topic).isOkOr:
      for prev in added:
        discard self.unsubscribe(prev, topic)
      return err(error)
    if isNew:
      added.add(target)
  return ok()

proc unsubscribe*(
    self: SubscriptionManager, topic: ContentTopic
): Result[void, string] =
  ## Unsubscribes from a content topic, resolving its shard via autosharding,
  ## and from every extra listen shard. A failure on one shard does not stop
  ## the others; the first error is returned.
  let shard = ?self.getShardForContentTopic(topic)
  var firstError = Opt.none(string)
  for target in self.topicShards(shard):
    self.unsubscribe(target, topic).isOkOr:
      if firstError.isNone():
        firstError = Opt.some(error)
  if firstError.isSome():
    return err(firstError.get())
  return ok()

proc unsubscribeAll*(
    self: SubscriptionManager, shard: PubsubTopic
): Result[void, string] =
  ## Drops every content topic on the shard, then the direct subscription.
  var snapshot: seq[ContentTopic]
  self.shards.withValue(shard, sub):
    snapshot = toSeq(sub.contentTopics)
  for contentTopic in snapshot:
    ?self.unsubscribe(shard, contentTopic)
  return self.unsubscribeShard(shard)

proc isSubscribed*(
    self: SubscriptionManager, topic: ContentTopic
): Result[bool, string] =
  let shard = ?self.getShardForContentTopic(topic)
  return ok(self.isContentSubscribed(shard, topic))

proc subscribeAllAutoshards*(self: SubscriptionManager): Result[void, string] =
  ## Subscribes the relay to every shard in the configured autosharding cluster.
  if self.protocols.relay.isNil() or self.getAutoSharding().isNone():
    return ok()

  let autoSharding = self.getAutoSharding().get()
  for shardId in autoSharding.shards:
    let shardObj = RelayShard(clusterId: autoSharding.clusterId, shardId: shardId)
    self.subscribeShard(PubsubTopic($shardObj)).isOkOr:
      error "failed to auto-subscribe relay to cluster shard",
        shard = $shardObj, error = error

  ok()

{.pop.}

proc edgeMode(self: SubscriptionManager): bool =
  ## Edge workers run only when relay is not mounted and the filter client is
  ## (otherwise the loops have nothing to talk to and spam "filter client is
  ## nil" warnings).
  return self.protocols.relay.isNil() and not self.protocols.filterClient.isNil()

proc start*(self: SubscriptionManager): Result[void, string] =
  return self.edgeFilter.start(runLoops = self.edgeMode())

proc stop*(self: SubscriptionManager) {.async: (raises: []).} =
  await self.edgeFilter.stop(loopsRunning = self.edgeMode())
