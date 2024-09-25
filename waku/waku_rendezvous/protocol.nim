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
): Future[Result[void, string]] {.async.} =
  ## Register with all rendez vous peers under a namespace

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
): Future[Result[seq[PeerRecord], string]] {.async.} =
  ## Request all records from all rendez vous peers with matching a namespace

  let catchable = catch:
    await RendezVous(self).request(namespace, count, peers)

  if catchable.isErr():
    return err(catchable.error.msg)

  return ok(catchable.get())

proc getRelayShards(enr: enr.Record): Option[RelayShards] =
  let typedRecord = enr.toTyped().valueOr:
    return none(RelayShards)

  return typedRecord.relaySharding()

proc new*(
    T: type WakuRendezVous, switch: Switch, peerManager: PeerManager, enr: Record
): T =
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

proc advertiseAll(self: WakuRendezVous) {.async.} =
  let pubsubTopics = self.relayShard.topics()

  let futs = collect(newSeq):
    for pubsubTopic in pubsubTopics:
      let namespace = computeNamespace(pubsubTopic.clusterId, pubsubTopic.shardId)

      # Get a random RDV peer for that shard
      let rpi = self.peerManager.selectPeer(RendezVousCodec, some($pubsubTopic)).valueOr:
        continue

      # Advertise yourself on that peer
      self.advertise(namespace, DefaultRegistrationTTL, @[rpi.peerId])

  let handles = await allFinished(futs)

  for fut in handles:
    let res = fut.read

    if res.isErr():
      warn "rendezvous advertise failed", error = res.error

  debug "waku rendezvous advertisements finished", adverCount = handles.len

proc initialRequestAll*(self: WakuRendezVous) {.async.} =
  let pubsubTopics = self.relayShard.topics()

  let futs = collect(newSeq):
    for pubsubTopic in pubsubTopics:
      let namespace = computeNamespace(pubsubTopic.clusterId, pubsubTopic.shardId)

      # Get a random RDV peer for that shard
      let rpi = self.peerManager.selectPeer(RendezVousCodec, some($pubsubTopic)).valueOr:
        continue

      # Ask for 12 peer records for that shard
      self.batchRequest(namespace, 12, @[rpi.peerId])

  let handles = await allFinished(futs)

  for fut in handles:
    let res = fut.read

    if res.isErr():
      warn "rendezvous request failed", error = res.error
    else:
      for peer in res.get():
        peerFoundTotal.inc()
        self.peerManager.addPeer(peer)

  debug "waku rendezvous requests finished", requestCount = handles.len

proc periodicRegistration(self: WakuRendezVous) {.async.} =
  debug "waku rendezvous periodic registration started",
    interval = DefaultRegistrationInterval

  # infinite loop
  while true:
    await sleepAsync(DefaultRegistrationInterval)

    await self.advertiseAll()

proc start*(self: WakuRendezVous) {.async.} =
  debug "starting waku rendezvous discovery"

  # start registering forever
  self.periodicRegistrationFut = self.periodicRegistration()

proc stopWait*(self: WakuRendezVous) {.async.} =
  debug "stopping waku rendezvous discovery"

  if not self.periodicRegistrationFut.isNil():
    await self.periodicRegistrationFut.cancelAndWait()
