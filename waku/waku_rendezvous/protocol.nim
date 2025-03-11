{.push raises: [].}

import
  std/[sugar, options],
  results,
  chronos,
  chronicles,
  metrics,
  libp2p/protocols/rendezvous,
  libp2p/switch,
  libp2p/utility

import
  ../node/peer_manager,
  ../common/enr,
  ../waku_enr/capabilities,
  ../waku_enr/sharding,
  ../waku_core/peers,
  ../waku_core/topics,
  ./common

logScope:
  topics = "waku rendezvous"

declarePublicCounter rendezvousPeerFoundTotal,
  "total number of peers found via rendezvous"

type WakuRendezVous* = ref object
  rendezvous: Rendezvous
  peerManager: PeerManager

  relayShard: RelayShards
  capabilities: seq[Capabilities]

  registrationInterval: timer.Duration
  periodicRegistrationFut: Future[void]

proc batchAdvertise*(
    self: WakuRendezVous,
    namespace: string,
    ttl: Duration = DefaultRegistrationTTL,
    peers: seq[PeerId],
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Register with all rendezvous peers under a namespace

  # rendezvous.advertise except already opened connections
  # must dial first
  var futs = collect(newSeq):
    for peerId in peers:
      self.peerManager.dialPeer(peerId, RendezVousCodec)

  let dialCatch = catch:
    await allFinished(futs)

  if dialCatch.isErr():
    return err("batchAdvertise: " & dialCatch.error.msg)

  futs = dialCatch.get()

  let conns = collect(newSeq):
    for fut in futs:
      let catchable = catch:
        fut.read()

      if catchable.isErr():
        error "rendezvous dial failed", error = catchable.error.msg
        continue

      let connOpt = catchable.get()

      let conn = connOpt.valueOr:
        continue

      conn

  let advertCatch = catch:
    await self.rendezvous.advertise(namespace, ttl, peers)

  for conn in conns:
    await conn.close()

  if advertCatch.isErr():
    return err("batchAdvertise: " & advertCatch.error.msg)

  return ok()

proc batchRequest*(
    self: WakuRendezVous,
    namespace: string,
    count: int = DiscoverLimit,
    peers: seq[PeerId],
): Future[Result[seq[PeerRecord], string]] {.async: (raises: []).} =
  ## Request all records from all rendezvous peers matching a namespace

  # rendezvous.request expect already opened connections
  # must dial first
  var futs = collect(newSeq):
    for peerId in peers:
      self.peerManager.dialPeer(peerId, RendezVousCodec)

  let dialCatch = catch:
    await allFinished(futs)

  if dialCatch.isErr():
    return err("batchRequest: " & dialCatch.error.msg)

  futs = dialCatch.get()

  let conns = collect(newSeq):
    for fut in futs:
      let catchable = catch:
        fut.read()

      if catchable.isErr():
        error "rendezvous dial failed", error = catchable.error.msg
        continue

      let connOpt = catchable.get()

      let conn = connOpt.valueOr:
        continue

      conn

  let reqCatch = catch:
    await self.rendezvous.request(namespace, count, peers)

  for conn in conns:
    await conn.close()

  if reqCatch.isErr():
    return err("batchRequest: " & reqCatch.error.msg)

  return ok(reqCatch.get())

proc advertiseAll(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  debug "waku rendezvous advertisements started"

  let pubsubTopics = self.relayShard.topics()

  let futs = collect(newSeq):
    for pubsubTopic in pubsubTopics:
      # Get a random RDV peer for that shard
      let rpi = self.peerManager.selectPeer(RendezVousCodec, some($pubsubTopic)).valueOr:
        continue

      let namespace = computeNamespace(pubsubTopic.clusterId, pubsubTopic.shardId)

      # Advertise yourself on that peer
      self.batchAdvertise(namespace, DefaultRegistrationTTL, @[rpi.peerId])

  if futs.len < 1:
    return err("could not get a peer supporting RendezVousCodec")

  let catchable = catch:
    await allFinished(futs)

  if catchable.isErr():
    return err(catchable.error.msg)

  for fut in catchable.get():
    if fut.failed():
      error "rendezvous advertisement failed", error = fut.error.msg

  debug "waku rendezvous advertisements finished"

  return ok()

proc initialRequestAll*(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  debug "waku rendezvous initial requests started"

  let pubsubTopics = self.relayShard.topics()

  let futs = collect(newSeq):
    for pubsubTopic in pubsubTopics:
      let namespace = computeNamespace(pubsubTopic.clusterId, pubsubTopic.shardId)

      # Get a random RDV peer for that shard
      let rpi = self.peerManager.selectPeer(RendezVousCodec, some($pubsubTopic)).valueOr:
        continue

      # Ask for peer records for that shard
      self.batchRequest(namespace, PeersRequestedCount, @[rpi.peerId])

  if futs.len < 1:
    return err("could not get a peer supporting RendezVousCodec")

  let catchable = catch:
    await allFinished(futs)

  if catchable.isErr():
    return err(catchable.error.msg)

  for fut in catchable.get():
    if fut.failed():
      error "rendezvous request failed", error = fut.error.msg
    elif fut.finished():
      let res = fut.value()

      let records = res.valueOr:
        return err($res.error)

      for record in records:
        rendezvousPeerFoundTotal.inc()
        self.peerManager.addPeer(record)

  debug "waku rendezvous initial requests finished"

  return ok()

proc periodicRegistration(self: WakuRendezVous) {.async.} =
  debug "waku rendezvous periodic registration started",
    interval = DefaultRegistrationInterval

  # infinite loop
  while true:
    await sleepAsync(self.registrationInterval)

    (await self.advertiseAll()).isOkOr:
      debug "waku rendezvous advertisements failed", error = error

      if self.registrationInterval > MaxRegistrationInterval:
        self.registrationInterval = MaxRegistrationInterval
      else:
        self.registrationInterval += self.registrationInterval

    # Back to normal interval if no errors
    self.registrationInterval = DefaultRegistrationInterval

proc new*(
    T: type WakuRendezVous, switch: Switch, peerManager: PeerManager, enr: Record
): Result[T, string] {.raises: [].} =
  let relayshard = getRelayShards(enr).valueOr:
    warn "Using default cluster id 0"
    RelayShards(clusterID: 0, shardIds: @[])

  let capabilities = enr.getCapabilities()

  let rvCatchable = catch:
    RendezVous.new(switch = switch, minDuration = DefaultRegistrationTTL)

  if rvCatchable.isErr():
    return err(rvCatchable.error.msg)

  let rv = rvCatchable.get()

  let mountCatchable = catch:
    switch.mount(rv)

  if mountCatchable.isErr():
    return err(mountCatchable.error.msg)

  var wrv = WakuRendezVous()
  wrv.rendezvous = rv
  wrv.peerManager = peerManager
  wrv.relayshard = relayshard
  wrv.capabilities = capabilities
  wrv.registrationInterval = DefaultRegistrationInterval

  debug "waku rendezvous initialized",
    cluster = relayshard.clusterId,
    shards = relayshard.shardIds,
    capabilities = capabilities

  return ok(wrv)

proc start*(self: WakuRendezVous) {.async: (raises: []).} =
  # start registering forever
  self.periodicRegistrationFut = self.periodicRegistration()

  debug "waku rendezvous discovery started"

proc stopWait*(self: WakuRendezVous) {.async: (raises: []).} =
  if not self.periodicRegistrationFut.isNil():
    await self.periodicRegistrationFut.cancelAndWait()

  debug "waku rendezvous discovery stopped"
