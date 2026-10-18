## Orchestration of the filter-client subscriptions of an edge (light) node.
##
## An edge node does not relay: it keeps, for each shard it follows, a small set
## of filter service peers subscribed to the content topics it wants, pings
## them, replaces the ones that go away, and reports the shard health.

import std/[sequtils, sets, tables]
import chronos, chronicles, results
import libp2p/[peerid, peerinfo]
import brokers/broker_context
import
  logos_delivery/kernel/[
    base/topics/content_topic,
    base/topics/pubsub_topic,
    base/peers,
    peer_manager/peer_manager,
    base/health/topic_health,
    base/health/health_requests,
    base/health/connection_status,
    events/health_events,
    events/peer_events,
    protocols/filter/common as filter_common,
    protocols/filter/client as filter_client,
    protocols/filter/protocol as filter_protocol,
  ]
type
  EdgeFilterSubState* = object
    peers*: seq[RemotePeerInfo]
    pending*: seq[Future[void]]
    pendingPeers*: HashSet[PeerId]
    currentHealth*: TopicHealth

  EdgeFilterSubscriptions* = ref object
    peerManager: PeerManager
    brokerCtx: BrokerContext
    getFilterClient: proc(): WakuFilterClient {.gcsafe, raises: [].}
      ## A callback because the filter client is mounted after this is built.
    desiredTopics:
      proc(): Table[PubsubTopic, HashSet[ContentTopic]] {.gcsafe, raises: [].}
      ## The content topics wanted on each shard; shards with none are left out.
    subStates*: Table[PubsubTopic, EdgeFilterSubState]
    wakeupEvent: AsyncEvent
    subLoopFut: Future[void]
    connectionLoopFut: Future[void]
    loopInterval*: Duration
    subLoopDebounce*: Duration
    peerEventListener: WakuPeerEventListener
    ownsShardHealthProvider: bool
    ownsPeerCountProvider: bool

const EdgeFilterLoopInterval = chronos.seconds(30)
  ## Interval for the edge filter health ping loop.
const EdgeFilterSubLoopDebounce = chronos.seconds(1)
  ## Debounce delay to coalesce rapid-fire wakeups into a single reconciliation pass.

proc new*(
    T: type EdgeFilterSubscriptions,
    peerManager: PeerManager,
    brokerCtx: BrokerContext,
    getFilterClient: proc(): WakuFilterClient {.gcsafe, raises: [].},
    desiredTopics:
      proc(): Table[PubsubTopic, HashSet[ContentTopic]] {.gcsafe, raises: [].},
): T =
  T(
    peerManager: peerManager,
    brokerCtx: brokerCtx,
    getFilterClient: getFilterClient,
    desiredTopics: desiredTopics,
    subStates: initTable[PubsubTopic, EdgeFilterSubState](),
    wakeupEvent: newAsyncEvent(),
    loopInterval: EdgeFilterLoopInterval,
    subLoopDebounce: EdgeFilterSubLoopDebounce,
  )

proc wake*(self: EdgeFilterSubscriptions) =
  ## Asks the reconciliation loop to re-read the wanted topics.
  self.wakeupEvent.fire()

func toTopicHealth*(peersCount: int): TopicHealth =
  if peersCount >= HealthyThreshold:
    return TopicHealth.SUFFICIENTLY_HEALTHY
  elif peersCount > 0:
    return TopicHealth.MINIMALLY_HEALTHY
  else:
    return TopicHealth.UNHEALTHY

const EdgeFilterSubscribeTimeout = chronos.seconds(15)
  ## Timeout for a single filter subscribe/unsubscribe RPC to a service peer.
const EdgeFilterPingTimeout = chronos.seconds(5)
  ## Timeout for a filter ping health check.

type EdgeFilterSubscribeTask = object
  peer: RemotePeerInfo
  shard: PubsubTopic
  topics: seq[ContentTopic]

proc updateShardHealth(
    self: EdgeFilterSubscriptions, shard: PubsubTopic, state: var EdgeFilterSubState
) =
  ## Recompute and emit health for a shard after its peer set changed.
  let newHealth = toTopicHealth(state.peers.len)
  if newHealth != state.currentHealth:
    state.currentHealth = newHealth
    EventShardTopicHealthChange.emit(self.brokerCtx, shard, newHealth)

proc removePeer(self: EdgeFilterSubscriptions, shard: PubsubTopic, peerId: PeerId) =
  ## Remove a peer from edgeFilterSubStates for the given shard,
  ## update health, and wake the sub loop to filter-subscribe a replacement.
  ## Best-effort unsubscribe so the service peer stops pushing to us.
  self.subStates.withValue(shard, state):
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
    self.wakeupEvent.fire()

    if not self.getFilterClient().isNil():
      var desired = self.desiredTopics()
      desired.withValue(shard, topics):
        let ct = toSeq(topics[])
        if ct.len > 0:
          proc doUnsubscribe() {.async.} =
            discard await self.getFilterClient().unsubscribe(peer, shard, ct)

          asyncSpawn doUnsubscribe()

type SendChunkedFilterRpcKind = enum
  FilterSubscribe
  FilterUnsubscribe

proc sendChunkedFilterRpc(
    self: EdgeFilterSubscriptions,
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
          self.getFilterClient().subscribe(peer, shard, chunk)
        of FilterUnsubscribe:
          self.getFilterClient().unsubscribe(peer, shard, chunk)
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
    self: EdgeFilterSubscriptions,
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
    self: EdgeFilterSubscriptions,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    contentTopics: seq[ContentTopic],
) {.async.} =
  ## Filter-subscribe to a service peer for all content topics on a shard and
  ## start tracking it (note that the filter client dials the peer if not connected).
  self.subStates.withValue(shard, state):
    state.pendingPeers.incl(peer.peerId)

  try:
    if not await self.sendChunkedFilterRpc(peer, shard, contentTopics, FilterSubscribe):
      return

    self.subStates.withValue(shard, state):
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
    self.subStates.withValue(shard, state):
      state.pendingPeers.excl(peer.peerId)

proc edgeFilterConnectionLoop(self: EdgeFilterSubscriptions) {.async.} =
  ## Periodically pings all tracked filter service peers to verify they are
  ## still alive at the application layer. Peers that fail the ping are removed.
  while true:
    await sleepAsync(self.loopInterval)

    if self.getFilterClient().isNil():
      debug "filter client is nil within edge filter connection loop"
      continue

    var connected = initTable[PeerId, RemotePeerInfo]()
    for state in self.subStates.values:
      for peer in state.peers:
        if self.peerManager.switch.peerStore.isConnected(peer.peerId):
          connected[peer.peerId] = peer

    var alive = initHashSet[PeerId]()

    if connected.len > 0:
      var pingTasks: seq[(PeerId, Future[FilterSubscribeResult])]
      for peer in connected.values:
        pingTasks.add(
          (peer.peerId, self.getFilterClient().ping(peer, EdgeFilterPingTimeout))
        )

      await allFutures(pingTasks.mapIt(it[1]))

      for (peerId, task) in pingTasks:
        if task.read().isOk():
          alive.incl(peerId)

    var changed = false
    for shard, state in self.subStates.mpairs:
      let oldLen = state.peers.len
      state.peers.keepItIf(it.peerId notin connected or alive.contains(it.peerId))

      if state.peers.len < oldLen:
        changed = true
        self.updateShardHealth(shard, state)
        trace "Edge Filter health degraded by Ping failure",
          shard = shard, new = state.currentHealth

    if changed:
      self.wakeupEvent.fire()

proc selectFilterCandidates(
    self: EdgeFilterSubscriptions,
    shard: PubsubTopic,
    exclude: HashSet[PeerId],
    needed: int,
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
  for otherShard, otherState in self.subStates.pairs:
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

proc edgeFilterSubLoop(self: EdgeFilterSubscriptions) {.async.} =
  ## Reconciles filter subscriptions with the desired state from SubscriptionManager.
  var lastSynced = initTable[PubsubTopic, HashSet[ContentTopic]]()

  while true:
    await self.wakeupEvent.wait()
    await sleepAsync(self.subLoopDebounce)
    self.wakeupEvent.clear()
    trace "edgeFilterSubLoop: woke up"

    if self.getFilterClient().isNil():
      trace "edgeFilterSubLoop: wakuFilterClient is nil, skipping"
      continue

    var newSynced = self.desiredTopics()
    var allShards: HashSet[PubsubTopic]
    for shard in newSynced.keys:
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

      discard self.subStates.mgetOrPut(
        shard, EdgeFilterSubState(currentHealth: TopicHealth.UNHEALTHY)
      )

      self.subStates.withValue(shard, state):
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
      self.subStates.withValue(shard, state):
        for fut in state.pending:
          if not fut.finished:
            await fut.cancelAndWait()
      self.subStates.del(shard)

    for task in subscribeTasks:
      let fut = self.subscribeFilterPeer(task.peer, task.shard, task.topics)
      self.subStates.withValue(task.shard, state):
        state.pending.add(fut)

    lastSynced = newSynced

proc startEdgeFilterLoops(self: EdgeFilterSubscriptions): Result[void, string] =
  ## Start the edge filter orchestration loops.
  ## Caller must ensure this is only called in edge mode (relay nil, filter client present).
  self.peerEventListener = WakuPeerEvent.listen(
    self.brokerCtx,
    proc(evt: WakuPeerEvent) {.async: (raises: []), gcsafe.} =
      if evt.kind == WakuPeerEventKind.EventDisconnected:
        # We know a peer is gone, so if it was a service filter peer for this
        # edge node, remove it from the list of service filter peers for each
        # shard it served and re-evaluate shard health for the affected shards.
        for shard, state in self.subStates.mpairs:
          let oldLen = state.peers.len
          state.peers.keepItIf(it.peerId != evt.peerId)
          if state.peers.len < oldLen:
            self.updateShardHealth(shard, state)
        self.wakeupEvent.fire()
      elif evt.kind in
          {WakuPeerEventKind.EventMetadataUpdated, WakuPeerEventKind.EventIdentified}:
        # identify lists the peer's protocols after the connection event
        self.wakeupEvent.fire(),
  ).valueOr:
    return err("Failed to listen to peer events for edge filter: " & error)

  self.subLoopFut = self.edgeFilterSubLoop()
  self.connectionLoopFut = self.edgeFilterConnectionLoop()
  return ok()

proc stopEdgeFilterLoops(self: EdgeFilterSubscriptions) {.async: (raises: []).} =
  ## Stop the edge filter orchestration loops and clean up pending futures.
  if not isNil(self.subLoopFut):
    await self.subLoopFut.cancelAndWait()
    self.subLoopFut = nil

  if not isNil(self.connectionLoopFut):
    await self.connectionLoopFut.cancelAndWait()
    self.connectionLoopFut = nil

  for shard, state in self.subStates:
    for fut in state.pending:
      if not fut.finished:
        await fut.cancelAndWait()

  await WakuPeerEvent.dropListener(self.brokerCtx, self.peerEventListener)

proc peerCount*(self: EdgeFilterSubscriptions, shard: PubsubTopic): int =
  self.subStates.withValue(shard, state):
    return state.peers.len
  return 0

proc start*(self: EdgeFilterSubscriptions, runLoops: bool): Result[void, string] =
  ## Registers the health providers, and starts the loops when `runLoops` is
  ## set: only a node without relay and with a filter client needs them.
  let edgeShardHealthRes = RequestEdgeShardHealth.setProvider(
    self.brokerCtx,
    proc(shard: PubsubTopic): Result[RequestEdgeShardHealth, string] =
      self.subStates.withValue(shard, state):
        return ok(RequestEdgeShardHealth(health: state.currentHealth))
      return ok(RequestEdgeShardHealth(health: TopicHealth.NOT_SUBSCRIBED)),
  )
  self.ownsShardHealthProvider = edgeShardHealthRes.isOk()
  if edgeShardHealthRes.isErr():
    error "Can't set provider for RequestEdgeShardHealth",
      error = edgeShardHealthRes.error

  let edgeFilterPeerCountRes = RequestEdgeFilterPeerCount.setProvider(
    self.brokerCtx,
    proc(): Result[RequestEdgeFilterPeerCount, string] =
      var minPeers = high(int)
      for state in self.subStates.values:
        minPeers = min(minPeers, state.peers.len)
      if minPeers == high(int):
        minPeers = 0
      return ok(RequestEdgeFilterPeerCount(peerCount: minPeers)),
  )
  self.ownsPeerCountProvider = edgeFilterPeerCountRes.isOk()
  if edgeFilterPeerCountRes.isErr():
    error "Can't set provider for RequestEdgeFilterPeerCount",
      error = edgeFilterPeerCountRes.error

  if runLoops:
    return self.startEdgeFilterLoops()

  return ok()

proc stop*(self: EdgeFilterSubscriptions, loopsRunning: bool) {.async: (raises: []).} =
  if loopsRunning:
    await self.stopEdgeFilterLoops()

  # Only clear providers we actually registered: another instance sharing this
  # brokerCtx may have won the race, and clearing its provider would leave the
  # broker silently provider-less.
  if self.ownsShardHealthProvider:
    RequestEdgeShardHealth.clearProvider(self.brokerCtx)
    self.ownsShardHealthProvider = false
  if self.ownsPeerCountProvider:
    RequestEdgeFilterPeerCount.clearProvider(self.brokerCtx)
    self.ownsPeerCountProvider = false
