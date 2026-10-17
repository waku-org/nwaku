import std/[sequtils, sets, tables], chronos, chronicles, metrics, results

import libp2p/[peerid, peerinfo]
import brokers/broker_context

import
  logos_delivery/kernel/[
    topics/content_topic,
    topics/pubsub_topic,
    topics/sharding,
    protocols/message,
    node/peer_manager/peers,
    protocols/codecs,
    protocols/protocols,
    protocols/relay/protocol,
    node/health_monitor/topic_health,
    archive/archive,
    protocols/store_sync/reconciliation,
    protocols/filter/common as filter_common,
    protocols/filter/client as filter_client,
    protocols/filter/protocol as filter_protocol,
    api/events/health_events,
    api/events/peer_events,
    api/events/subscription_events,
    requests/health_requests,
    node/peer_manager/peer_manager,
    node/health_monitor/connection_status,
  ]
import logos_delivery/api/events/kernel_events

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

type EdgeFilterSubState* = object
  peers*: seq[RemotePeerInfo]
  pending*: seq[Future[void]]
  pendingPeers*: HashSet[PeerId]
  currentHealth*: TopicHealth

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
  edgeFilterSubStates*: Table[PubsubTopic, EdgeFilterSubState]
  edgeFilterWakeup*: AsyncEvent
  edgeFilterSubLoopFut*: Future[void]
  edgeFilterConnectionLoopFut*: Future[void]
  edgeFilterLoopInterval*: Duration
  edgeFilterSubLoopDebounce*: Duration
  peerEventListener*: WakuPeerEventListener
  ownsEdgeShardHealthProvider*: bool
  ownsEdgeFilterPeerCountProvider*: bool

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

const EdgeFilterLoopInterval = chronos.seconds(30)
  ## Interval for the edge filter health ping loop.
const EdgeFilterSubLoopDebounce = chronos.seconds(1)
  ## Debounce delay to coalesce rapid-fire wakeups into a single reconciliation pass.

proc new*(
    T: type SubscriptionManager,
    protocols: Protocols,
    peerManager: PeerManager,
    brokerCtx: BrokerContext,
    getAutoSharding: proc(): Opt[Sharding] {.gcsafe, raises: [].},
): T =
  T(
    protocols: protocols,
    peerManager: peerManager,
    brokerCtx: brokerCtx,
    getAutoSharding: getAutoSharding,
    shards: initTable[PubsubTopic, ShardSubscription](),
    edgeFilterSubStates: initTable[PubsubTopic, EdgeFilterSubState](),
    edgeFilterWakeup: newAsyncEvent(),
    edgeFilterLoopInterval: EdgeFilterLoopInterval,
    edgeFilterSubLoopDebounce: EdgeFilterSubLoopDebounce,
  )

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

func toTopicHealth*(peersCount: int): TopicHealth =
  if peersCount >= HealthyThreshold:
    return TopicHealth.SUFFICIENTLY_HEALTHY
  elif peersCount > 0:
    return TopicHealth.MINIMALLY_HEALTHY
  else:
    return TopicHealth.UNHEALTHY

proc edgeFilterPeerCount*(self: SubscriptionManager, shard: PubsubTopic): int =
  self.edgeFilterSubStates.withValue(shard, state):
    return state.peers.len
  return 0

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
    self.edgeFilterWakeup.fire()
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
    self.edgeFilterWakeup.fire()
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
    self.edgeFilterWakeup.fire()
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
    self.edgeFilterWakeup.fire()
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

const EdgeFilterSubscribeTimeout = chronos.seconds(15)
  ## Timeout for a single filter subscribe/unsubscribe RPC to a service peer.
const EdgeFilterPingTimeout = chronos.seconds(5)
  ## Timeout for a filter ping health check.

type EdgeFilterSubscribeTask = object
  peer: RemotePeerInfo
  shard: PubsubTopic
  topics: seq[ContentTopic]

proc updateShardHealth(
    self: SubscriptionManager, shard: PubsubTopic, state: var EdgeFilterSubState
) =
  ## Recompute and emit health for a shard after its peer set changed.
  let newHealth = toTopicHealth(state.peers.len)
  if newHealth != state.currentHealth:
    state.currentHealth = newHealth
    EventShardTopicHealthChange.emit(self.brokerCtx, shard, newHealth)

proc removePeer(self: SubscriptionManager, shard: PubsubTopic, peerId: PeerId) =
  ## Remove a peer from edgeFilterSubStates for the given shard,
  ## update health, and wake the sub loop to filter-subscribe a replacement.
  ## Best-effort unsubscribe so the service peer stops pushing to us.
  self.edgeFilterSubStates.withValue(shard, state):
    var idx = -1
    for i, p in state.peers:
      if p.peerId == peerId:
        idx = i
        break
    if idx < 0:
      return

    let peer = state.peers[idx]
    state.peers.del(idx)
    self.updateShardHealth(shard, state[])
    self.edgeFilterWakeup.fire()

    if not self.protocols.filterClient.isNil():
      self.shards.withValue(shard, sub):
        let ct = toSeq(sub.contentTopics)
        if ct.len > 0:
          proc doUnsubscribe() {.async.} =
            discard await self.protocols.filterClient.unsubscribe(peer, shard, ct)

          asyncSpawn doUnsubscribe()

type SendChunkedFilterRpcKind = enum
  FilterSubscribe
  FilterUnsubscribe

proc sendChunkedFilterRpc(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    topics: seq[ContentTopic],
    kind: SendChunkedFilterRpcKind,
): Future[bool] {.async.} =
  ## Send a chunked filter subscribe or unsubscribe RPC. Returns true on
  ## success. On failure the peer is removed and false is returned.
  try:
    var i = 0
    while i < topics.len:
      let chunk =
        topics[i ..< min(i + filter_protocol.MaxContentTopicsPerRequest, topics.len)]
      let fut =
        case kind
        of FilterSubscribe:
          self.protocols.filterClient.subscribe(peer, shard, chunk)
        of FilterUnsubscribe:
          self.protocols.filterClient.unsubscribe(peer, shard, chunk)
      if not (await fut.withTimeout(EdgeFilterSubscribeTimeout)) or fut.read().isErr():
        trace "sendChunkedFilterRpc: chunk failed",
          op = kind, shard = shard, peer = peer.peerId
        self.removePeer(shard, peer.peerId)
        return false
      i += filter_protocol.MaxContentTopicsPerRequest
  except CatchableError as exc:
    debug "sendChunkedFilterRpc: failed",
      op = kind, shard = shard, peer = peer.peerId, err = exc.msg
    self.removePeer(shard, peer.peerId)
    return false
  return true

proc syncFilterDeltas(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    added: seq[ContentTopic],
    removed: seq[ContentTopic],
) {.async.} =
  ## Push content topic changes (adds/removes) to an already-tracked peer.
  if added.len > 0:
    if not await self.sendChunkedFilterRpc(peer, shard, added, FilterSubscribe):
      return

  if removed.len > 0:
    discard await self.sendChunkedFilterRpc(peer, shard, removed, FilterUnsubscribe)

proc subscribeFilterPeer(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    contentTopics: seq[ContentTopic],
) {.async.} =
  ## Filter-subscribe to a service peer for all content topics on a shard and
  ## start tracking it (note that the filter client dials the peer if not connected).
  self.edgeFilterSubStates.withValue(shard, state):
    state.pendingPeers.incl(peer.peerId)

  try:
    if not await self.sendChunkedFilterRpc(peer, shard, contentTopics, FilterSubscribe):
      return

    self.edgeFilterSubStates.withValue(shard, state):
      if state.peers.anyIt(it.peerId == peer.peerId):
        trace "subscribeFilterPeer: peer already tracked, skipping duplicate",
          shard = shard, peer = peer.peerId
        return

      state.peers.add(peer)
      self.updateShardHealth(shard, state[])
      trace "subscribeFilterPeer: successfully subscribed to all chunks",
        shard = shard, peer = peer.peerId, totalPeers = state.peers.len
    do:
      trace "subscribeFilterPeer: shard removed while subscribing, discarding result",
        shard = shard, peer = peer.peerId
  finally:
    self.edgeFilterSubStates.withValue(shard, state):
      state.pendingPeers.excl(peer.peerId)

proc edgeFilterConnectionLoop(self: SubscriptionManager) {.async.} =
  ## Periodically pings all tracked filter service peers to verify they are
  ## still alive at the application layer. Peers that fail the ping are removed.
  while true:
    await sleepAsync(self.edgeFilterLoopInterval)

    if self.protocols.filterClient.isNil():
      debug "filter client is nil within edge filter connection loop"
      continue

    var connected = initTable[PeerId, RemotePeerInfo]()
    for state in self.edgeFilterSubStates.values:
      for peer in state.peers:
        if self.peerManager.switch.peerStore.isConnected(peer.peerId):
          connected[peer.peerId] = peer

    var alive = initHashSet[PeerId]()

    if connected.len > 0:
      var pingTasks: seq[(PeerId, Future[FilterSubscribeResult])]
      for peer in connected.values:
        pingTasks.add(
          (peer.peerId, self.protocols.filterClient.ping(peer, EdgeFilterPingTimeout))
        )

      await allFutures(pingTasks.mapIt(it[1]))

      for (peerId, task) in pingTasks:
        if task.read().isOk():
          alive.incl(peerId)

    var changed = false
    for shard, state in self.edgeFilterSubStates.mpairs:
      let oldLen = state.peers.len
      state.peers.keepItIf(it.peerId notin connected or alive.contains(it.peerId))

      if state.peers.len < oldLen:
        changed = true
        self.updateShardHealth(shard, state)
        trace "Edge Filter health degraded by Ping failure",
          shard = shard, new = state.currentHealth

    if changed:
      self.edgeFilterWakeup.fire()

proc selectFilterCandidates(
    self: SubscriptionManager, shard: PubsubTopic, exclude: HashSet[PeerId], needed: int
): seq[RemotePeerInfo] =
  ## Select filter service peer candidates for a shard.

  # Start with every filter server peer that can serve the shard
  var allCandidates = self.peerManager.selectPeers(
    filter_common.WakuFilterSubscribeCodec, Opt.some(shard)
  )

  # Remove all already used in this shard or being filter-subscribed for it
  allCandidates.keepItIf(it.peerId notin exclude)

  # Collect peer IDs already tracked on other shards
  var trackedOnOther = initHashSet[PeerId]()
  for otherShard, otherState in self.edgeFilterSubStates.pairs:
    if otherShard != shard:
      for peer in otherState.peers:
        trackedOnOther.incl(peer.peerId)

  # Prefer peers we already have a connection to first, preserving shuffle
  var candidates =
    allCandidates.filterIt(it.peerId in trackedOnOther) &
    allCandidates.filterIt(it.peerId notin trackedOnOther)

  # We need to return 'needed' peers only
  if candidates.len > needed:
    candidates.setLen(needed)
  return candidates

proc edgeFilterSubLoop(self: SubscriptionManager) {.async.} =
  ## Reconciles filter subscriptions with the desired state from SubscriptionManager.
  var lastSynced = initTable[PubsubTopic, HashSet[ContentTopic]]()

  while true:
    await self.edgeFilterWakeup.wait()
    await sleepAsync(self.edgeFilterSubLoopDebounce)
    self.edgeFilterWakeup.clear()
    trace "edgeFilterSubLoop: woke up"

    if isNil(self.protocols.filterClient):
      trace "edgeFilterSubLoop: wakuFilterClient is nil, skipping"
      continue

    var newSynced = initTable[PubsubTopic, HashSet[ContentTopic]]()
    var allShards: HashSet[PubsubTopic]
    for shard, sub in self.shards.pairs:
      if sub.contentTopics.len > 0:
        newSynced[shard] = sub.contentTopics
        allShards.incl(shard)
    for shard in lastSynced.keys:
      allShards.incl(shard)

    trace "edgeFilterSubLoop: desired state", numShards = newSynced.len

    # Step 1: read state across all shards at once and
    # create a list of peer filter-subscribe tasks and shard tracking to delete.

    var subscribeTasks: seq[EdgeFilterSubscribeTask]
    var shardsToDelete: seq[PubsubTopic]

    for shard in allShards:
      # Compute added/removed deltas via direct iteration; no HashSet copies.
      var addedTopics: seq[ContentTopic]
      var removedTopics: seq[ContentTopic]
      newSynced.withValue(shard, curr):
        lastSynced.withValue(shard, prev):
          for t in curr[]:
            if t notin prev[]:
              addedTopics.add(t)
          for t in prev[]:
            if t notin curr[]:
              removedTopics.add(t)
        do:
          for t in curr[]:
            addedTopics.add(t)
      do:
        lastSynced.withValue(shard, prev):
          for t in prev[]:
            removedTopics.add(t)

      discard self.edgeFilterSubStates.mgetOrPut(
        shard, EdgeFilterSubState(currentHealth: TopicHealth.UNHEALTHY)
      )

      self.edgeFilterSubStates.withValue(shard, state):
        state.peers.keepItIf(self.peerManager.switch.peerStore.isConnected(it.peerId))
        state.pending.keepItIf(not it.finished)

        if addedTopics.len > 0 or removedTopics.len > 0:
          for peer in state.peers:
            asyncSpawn self.syncFilterDeltas(peer, shard, addedTopics, removedTopics)

        if shard notin newSynced:
          shardsToDelete.add(shard)
        else:
          self.updateShardHealth(shard, state[])

          let needed = max(0, HealthyThreshold - state.peers.len - state.pending.len)

          if needed > 0:
            var tracked: HashSet[PeerId]
            for p in state.peers:
              tracked.incl(p.peerId)
            for p in state.pendingPeers:
              tracked.incl(p)
            let candidates = self.selectFilterCandidates(shard, tracked, needed)
            let toSubscribe = min(needed, candidates.len)

            trace "edgeFilterSubLoop: shard reconciliation",
              shard = shard,
              num_peers = state.peers.len,
              num_pending = state.pending.len,
              num_needed = needed,
              num_available = candidates.len,
              toSubscribe = toSubscribe

            var subscribeTopics: seq[ContentTopic]
            newSynced.withValue(shard, curr):
              subscribeTopics = toSeq(curr[])

            for i in 0 ..< toSubscribe:
              subscribeTasks.add(
                EdgeFilterSubscribeTask(
                  peer: candidates[i], shard: shard, topics: subscribeTopics
                )
              )

    # Step 2: execute deferred shard tracking deletion and filter-subscribe tasks.

    for shard in shardsToDelete:
      self.edgeFilterSubStates.withValue(shard, state):
        for fut in state.pending:
          if not fut.finished:
            await fut.cancelAndWait()
      self.edgeFilterSubStates.del(shard)

    for task in subscribeTasks:
      let fut = self.subscribeFilterPeer(task.peer, task.shard, task.topics)
      self.edgeFilterSubStates.withValue(task.shard, state):
        state.pending.add(fut)

    lastSynced = newSynced

proc startEdgeFilterLoops(self: SubscriptionManager): Result[void, string] =
  ## Start the edge filter orchestration loops.
  ## Caller must ensure this is only called in edge mode (relay nil, filter client present).
  self.peerEventListener = WakuPeerEvent.listen(
    self.brokerCtx,
    proc(evt: WakuPeerEvent) {.async: (raises: []), gcsafe.} =
      if evt.kind == WakuPeerEventKind.EventDisconnected:
        # We know a peer is gone, so if it was a service filter peer for this
        # edge node, remove it from the list of service filter peers for each
        # shard it served and re-evaluate shard health for the affected shards.
        for shard, state in self.edgeFilterSubStates.mpairs:
          let oldLen = state.peers.len
          state.peers.keepItIf(it.peerId != evt.peerId)
          if state.peers.len < oldLen:
            self.updateShardHealth(shard, state)
        self.edgeFilterWakeup.fire()
      elif evt.kind in
          {WakuPeerEventKind.EventMetadataUpdated, WakuPeerEventKind.EventIdentified}:
        # identify lists the peer's protocols after the connection event
        self.edgeFilterWakeup.fire(),
  ).valueOr:
    return err("Failed to listen to peer events for edge filter: " & error)

  self.edgeFilterSubLoopFut = self.edgeFilterSubLoop()
  self.edgeFilterConnectionLoopFut = self.edgeFilterConnectionLoop()
  return ok()

proc stopEdgeFilterLoops(self: SubscriptionManager) {.async: (raises: []).} =
  ## Stop the edge filter orchestration loops and clean up pending futures.
  if not isNil(self.edgeFilterSubLoopFut):
    await self.edgeFilterSubLoopFut.cancelAndWait()
    self.edgeFilterSubLoopFut = nil

  if not isNil(self.edgeFilterConnectionLoopFut):
    await self.edgeFilterConnectionLoopFut.cancelAndWait()
    self.edgeFilterConnectionLoopFut = nil

  for shard, state in self.edgeFilterSubStates:
    for fut in state.pending:
      if not fut.finished:
        await fut.cancelAndWait()

  await WakuPeerEvent.dropListener(self.brokerCtx, self.peerEventListener)

proc start*(self: SubscriptionManager): Result[void, string] =
  let edgeShardHealthRes = RequestEdgeShardHealth.setProvider(
    self.brokerCtx,
    proc(shard: PubsubTopic): Result[RequestEdgeShardHealth, string] =
      self.edgeFilterSubStates.withValue(shard, state):
        return ok(RequestEdgeShardHealth(health: state.currentHealth))
      return ok(RequestEdgeShardHealth(health: TopicHealth.NOT_SUBSCRIBED)),
  )
  self.ownsEdgeShardHealthProvider = edgeShardHealthRes.isOk()
  if edgeShardHealthRes.isErr():
    error "Can't set provider for RequestEdgeShardHealth",
      error = edgeShardHealthRes.error

  let edgeFilterPeerCountRes = RequestEdgeFilterPeerCount.setProvider(
    self.brokerCtx,
    proc(): Result[RequestEdgeFilterPeerCount, string] =
      var minPeers = high(int)
      for state in self.edgeFilterSubStates.values:
        minPeers = min(minPeers, state.peers.len)
      if minPeers == high(int):
        minPeers = 0
      return ok(RequestEdgeFilterPeerCount(peerCount: minPeers)),
  )
  self.ownsEdgeFilterPeerCountProvider = edgeFilterPeerCountRes.isOk()
  if edgeFilterPeerCountRes.isErr():
    error "Can't set provider for RequestEdgeFilterPeerCount",
      error = edgeFilterPeerCountRes.error

  # Start Edge workers only when we are in Edge mode (relay not mounted)
  # AND the filter client is mounted (otherwise the loops have nothing
  # to talk to and just spam "filter client is nil" warnings).
  if self.protocols.relay.isNil() and not self.protocols.filterClient.isNil():
    return self.startEdgeFilterLoops()

  return ok()

proc stop*(self: SubscriptionManager) {.async: (raises: []).} =
  # Stop Edge workers if we started them in `start` (Edge mode + filter client).
  if self.protocols.relay.isNil() and not self.protocols.filterClient.isNil():
    await self.stopEdgeFilterLoops()

  # Only clear providers we actually registered: another SubscriptionManager
  # sharing this brokerCtx may have won the race, and clearing its provider
  # would leave the broker silently provider-less.
  if self.ownsEdgeShardHealthProvider:
    RequestEdgeShardHealth.clearProvider(self.brokerCtx)
    self.ownsEdgeShardHealthProvider = false
  if self.ownsEdgeFilterPeerCountProvider:
    RequestEdgeFilterPeerCount.clearProvider(self.brokerCtx)
    self.ownsEdgeFilterPeerCountProvider = false
