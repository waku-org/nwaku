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
  ../waku_core/peers as peers,
  ./common

logScope:
  topics = "waku rendez vous"

declarePublicCounter peerFound, "number of peers found via rendezvous"

type WakuRendezVous* = ref object of RendezVous
  peerManager: PeerManager
  relayShard: RelayShards
  capabilities: seq[Capabilities]

  periodicRegistrationFut: Future[void]

  clientOnly: bool

proc advertise(
    self: WakuRendezVous, namespace: string, ttl: Duration = MinimumDuration
): Future[Result[void, string]] {.async.} =
  ## Register with all rendez vous peers under a namespace

  let catchable = catch:
    await procCall RendezVous(self).advertise(namespace, ttl)

  if catchable.isErr():
    return err(catchable.error.msg)

  return ok()

proc request(
    self: WakuRendezVous, namespace: string, count: int = DiscoverLimit
): Future[Result[seq[PeerRecord], string]] {.async.} =
  ## Request all records from all rendez vous peers with matching a namespace

  let catchable = catch:
    await RendezVous(self).request(namespace, count)

  if catchable.isErr():
    return err(catchable.error.msg)

  return ok(catchable.get())

proc requestLocally(self: WakuRendezVous, namespace: string): seq[PeerRecord] =
  RendezVous(self).requestLocally(namespace)

proc unsubscribeLocally(self: WakuRendezVous, namespace: string) =
  RendezVous(self).unsubscribeLocally(namespace)

proc unsubscribe(
    self: WakuRendezVous, namespace: string
): Future[Result[void, string]] {.async.} =
  ## Unsubscribe from all rendez vous peers including locally

  let catchable = catch:
    await RendezVous(self).unsubscribe(namespace)

  if catchable.isErr():
    return err(catchable.error.msg)

  return ok()

proc getRelayShards(enr: enr.Record): Option[RelayShards] =
  let typedRecord = enr.toTyped().valueOr:
    return none(RelayShards)

  return typedRecord.relaySharding()

proc new*(
    T: type WakuRendezVous,
    switch: Switch,
    peerManager: PeerManager,
    enr: Record,
    enabled: bool,
): T =
  let relayshard = getRelayShards(enr).valueOr:
    warn "Using default cluster id 0"
    RelayShards(clusterID: 0, shardIds: @[])

  let capabilities = enr.getCapabilities()

  let wrv = WakuRendezVous(
    peerManager: peerManager,
    relayshard: relayshard,
    capabilities: capabilities,
    clientOnly: clientOnly,
  )

  RendezVous(wrv).setup(switch)

  debug "waku rendezvous initialized",
    cluster = relayshard.clusterId,
    shards = relayshard.shardIds,
    capabilities = capabilities

  return wrv

proc advertisementNamespaces(self: WakuRendezVous): seq[string] =
  let namespaces = collect(newSeq):
    for shard in self.relayShard.shardIds:
      for cap in self.capabilities:
        computeNamespace(self.relayShard.clusterId, shard, cap)

  return namespaces

proc requestNamespaces(self: WakuRendezVous): seq[string] =
  let namespaces = collect(newSeq):
    for shard in self.relayShard.shardIds:
      for cap in Capabilities:
        computeNamespace(self.relayShard.clusterId, shard, cap)

  return namespaces

proc shardOnlyNamespaces(self: WakuRendezVous): seq[string] =
  let namespaces = collect(newSeq):
    for shard in self.relayShard.shardIds:
      computeNamespace(self.relayShard.clusterId, shard)

  return namespaces

proc advertiseAll*(self: WakuRendezVous) {.async.} =
  let namespaces = self.shardOnlyNamespaces()

  let futs = collect(newSeq):
    for namespace in namespaces:
      self.advertise(namespace)

  let handles = await allFinished(futs)

  for fut in handles:
    let res = fut.read

    if res.isErr():
      warn "failed to advertise", error = res.error

  debug "waku rendezvous advertisements finished", adverCount = handles.len

proc requestAll*(self: WakuRendezVous) {.async.} =
  let namespaces = self.shardOnlyNamespaces()

  let futs = collect(newSeq):
    for namespace in namespaces:
      self.request(namespace)

  let handles = await allFinished(futs)

  for fut in handles:
    let res = fut.read

    if res.isErr():
      warn "failed to request", error = res.error
    else:
      for peer in res.get():
        peerFound.inc()
        self.peerManager.addPeer(peer)

  debug "waku rendezvous requests finished", requestCount = handles.len

proc unsubcribeAll*(self: WakuRendezVous) {.async.} =
  let namespaces = self.shardOnlyNamespaces()

  let futs = collect(newSeq):
    for namespace in namespaces:
      self.unsubscribe(namespace)

  let handles = await allFinished(futs)

  for fut in handles:
    let res = fut.read

    if res.isErr():
      warn "failed to unsubcribe", error = res.error

  debug "waku rendezvous unsubscriptions finished", unsubCount = handles.len

  return

proc periodicRegistration(self: WakuRendezVous) {.async.} =
  debug "waku rendezvous periodic registration started",
    interval = DefaultRegistrationInterval

  # infinite loop
  while true:
    # default ttl of registration is the same as default interval
    await self.advertiseAll()

    await sleepAsync(DefaultRegistrationInterval)

proc start*(self: WakuRendezVous) {.async.} =
  await self.requestAll()

  if not self.enabled:
    return

  debug "starting waku rendezvous discovery"

  # start registering forever
  self.periodicRegistrationFut = self.periodicRegistration()

proc stopWait*(self: WakuRendezVous) {.async.} =
  if not self.enabled:
    return

  debug "stopping waku rendezvous discovery"

  await self.unsubcribeAll()

  if not self.periodicRegistrationFut.isNil():
    await self.periodicRegistrationFut.cancelAndWait()
