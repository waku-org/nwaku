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
  topics = "waku rendez vous"

declarePublicCounter peerFoundTotal, "total number of peers found via rendezvous"

type WakuRendezVous* = ref object of RendezVous
  peerManager: PeerManager
  relayShard: RelayShards
  capabilities: seq[Capabilities]

  periodicRegistrationFut: Future[void]

proc batchAdvertise*(
    self: WakuRendezVous,
    namespace: string,
    ttl: Duration = MinimumDuration,
    peers: seq[PeerId],
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Register with all rendezvous peers under a namespace

  let catchable = catch:
    await procCall RendezVous(self).advertise(namespace, ttl, peers)

  if catchable.isErr():
    return err(catchable.error.msg)

  return ok()

proc batchRequest*(
    self: WakuRendezVous,
    namespace: string,
    count: int = DiscoverLimit,
    peers: seq[PeerId],
): Future[Result[seq[PeerRecord], string]] {.async: (raises: []).} =
  ## Request all records from all rendezvous peers matching a namespace

  let catchable = catch:
    await RendezVous(self).request(namespace, count, peers)

  if catchable.isErr():
    return err(catchable.error.msg)

  return ok(catchable.get())

proc advertiseAll(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  let pubsubTopics = self.relayShard.topics()

  let futs = collect(newSeq):
    for pubsubTopic in pubsubTopics:
      let namespace = computeNamespace(pubsubTopic.clusterId, pubsubTopic.shardId)

      # Get a random RDV peer for that shard
      let rpi = self.peerManager.selectPeer(RendezVousCodec, some($pubsubTopic)).valueOr:
        continue

      # Advertise yourself on that peer
      self.advertise(namespace, DefaultRegistrationTTL, @[rpi.peerId])

  let catchable = catch:
    await allFinished(futs)

  if catchable.isErr():
    return err(catchable.error.msg)

  for fut in catchable.get():
    if fut.failed():
      warn "rendezvous advertisement failed", error = fut.error.msg

  debug "waku rendezvous advertisements finished"

  return ok()

proc initialRequestAll*(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  let pubsubTopics = self.relayShard.topics()

  let futs = collect(newSeq):
    for pubsubTopic in pubsubTopics:
      let namespace = computeNamespace(pubsubTopic.clusterId, pubsubTopic.shardId)

      # Get a random RDV peer for that shard
      let rpi = self.peerManager.selectPeer(RendezVousCodec, some($pubsubTopic)).valueOr:
        continue

      # Ask for 12 peer records for that shard
      self.request(namespace, 12, @[rpi.peerId])

  let catchable = catch:
    await allFinished(futs)

  if catchable.isErr():
    return err(catchable.error.msg)

  for fut in catchable.get():
    if fut.failed():
      warn "rendezvous request failed", error = fut.error.msg
    elif fut.finished():
      let peers = fut.value()

      for peer in peers:
        peerFoundTotal.inc()
        self.peerManager.addPeer(peer)

  debug "waku rendezvous requests finished"

  return ok()

proc periodicRegistration(self: WakuRendezVous) {.async.} =
  debug "waku rendezvous periodic registration started",
    interval = DefaultRegistrationInterval

  # infinite loop
  while true:
    await sleepAsync(DefaultRegistrationInterval)

    (await self.advertiseAll()).isOkOr:
      debug "waku rendezvous advertisements failed", error = error

proc getRelayShards(enr: enr.Record): Option[RelayShards] =
  let typedRecord = enr.toTyped().valueOr:
    return none(RelayShards)

  return typedRecord.relaySharding()

proc new*(
    T: type WakuRendezVous, switch: Switch, peerManager: PeerManager, enr: Record
): T {.raises: [].} =
  let relayshard = getRelayShards(enr).valueOr:
    warn "Using default cluster id 0"
    RelayShards(clusterID: 0, shardIds: @[])

  let capabilities = enr.getCapabilities()

  let wrv = WakuRendezVous(
    peerManager: peerManager, relayshard: relayshard, capabilities: capabilities
  )

  RendezVous(wrv).setup(switch)

  debug "waku rendezvous initialized",
    cluster = relayshard.clusterId,
    shards = relayshard.shardIds,
    capabilities = capabilities

  return wrv

proc start*(self: WakuRendezVous) {.async: (raises: []).} =
  debug "starting waku rendezvous discovery"

  # start registering forever
  self.periodicRegistrationFut = self.periodicRegistration()

proc stopWait*(self: WakuRendezVous) {.async: (raises: []).} =
  debug "stopping waku rendezvous discovery"

  if not self.periodicRegistrationFut.isNil():
    await self.periodicRegistrationFut.cancelAndWait()
