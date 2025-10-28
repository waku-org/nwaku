{.push raises: [].}

import
  std/[sugar, options, sequtils, algorithm, tables],
  results,
  chronos,
  chronicles,
  stew/byteutils,
  libp2p/protocols/rendezvous,
  libp2p/protocols/rendezvous/protobuf,
  libp2p/discovery/discoverymngr,
  libp2p/utils/semaphore,
  libp2p/utils/offsettedseq,
  libp2p/crypto/curve25519,
  libp2p/switch,
  libp2p/utility

import metrics except collect

import
  ../node/peer_manager,
  ../common/callbacks,
  ../waku_enr/capabilities,
  ../waku_core/peers,
  ../waku_core/codecs,
  ../waku_core/topics,
  ../waku_core/topics/pubsub_topic,
  ./common,
  ./waku_peer_record

# Explicitly make the items iterator visible in this module's scope
# This is needed for generic instantiation of rendezvous methods
iterator items*[T](o: OffsettedSeq[T]): T =
  for item in offsettedseq.items(o):
    yield item

logScope:
  topics = "waku rendezvous"

declarePublicCounter rendezvousPeerFoundTotal,
  "total number of peers found via rendezvous"

type WakuRendezVous* = ref object of GenericRendezVous[WakuPeerRecord]
  peerManager: PeerManager
  clusterId: uint16
  getShards: GetShards
  getCapabilities: GetCapabilities
  getPeerRecord: GetWakuPeerRecord

  registrationInterval: timer.Duration
  periodicRegistrationFut: Future[void]

  requestInterval: timer.Duration
  periodicRequestFut: Future[void]
  clientOnlyMode: bool

# Override discover method to avoid collect macro generic instantiation issues
# TODO figure out if we can use parent generic discover
method discover*(
    self: WakuRendezVous, conn: Connection, d: Discover
) {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Received Discover", peerId = conn.peerId, ns = d.ns
  if d.ns.isSome() and d.ns.get().len > 255: #MaximumNamespaceLen
    await conn.sendDiscoverResponseError(InvalidNamespace)
    return

  var limit = min(1000'u64, d.limit.get(1000'u64)) # DiscoverLimit
  var cookie =
    if d.cookie.isSome():
      try:
        Cookie.decode(d.cookie.tryGet()).tryGet()
      except CatchableError:
        await conn.sendDiscoverResponseError(InvalidCookie)
        return
    else:
      # Start from the current lowest index (inclusive)
      Cookie(offset: self.registered.low().uint64)
  if d.ns.isSome() and cookie.ns.isSome() and cookie.ns.get() != d.ns.get():
    # Namespace changed: start from the beginning of that namespace
    cookie = Cookie(offset: self.registered.low().uint64)
  elif cookie.offset < self.registered.low().uint64:
    # Cookie behind available range: reset to current low
    cookie.offset = self.registered.low().uint64
  elif cookie.offset > (self.registered.high() + 1).uint64:
    # Cookie ahead of available range: reset to one past current high (empty page)
    cookie.offset = (self.registered.high() + 1).uint64
  let namespaces =
    if d.ns.isSome():
      let nsKey = d.ns.get() & self.salt
      let ns = self.namespaces.getOrDefault(nsKey, @[])
      if ns.len == 0:
        await conn.sendDiscoverResponseError(InvalidNamespace)
        return
      ns
    else:
      toSeq(max(cookie.offset.int, self.registered.offset) .. self.registered.high())
  if namespaces.len() == 0:
    await conn.sendDiscoverResponse(@[], Cookie())
    return
  var nextOffset = cookie.offset
  let n = Moment.now()
  var s = collect(newSeq()):
    for index in namespaces:
      var reg = self.registered[index]
      if limit == 0:
        break
      if reg.expiration < n or index.uint64 < cookie.offset:
        continue
      limit.dec()
      nextOffset = index.uint64 + 1
      reg.data.ttl = Opt.some((reg.expiration - Moment.now()).seconds.uint64)
      reg.data
  self.rng.shuffle(s)
  await conn.sendDiscoverResponse(s, Cookie(offset: nextOffset, ns: d.ns))

proc advertise*(
    self: WakuRendezVous,
    namespace: string,
    peers: seq[PeerId],
    ttl: timer.Duration = self.minDuration,
): Future[Result[void, string]] {.async: (raises: []).} =
  if self.clientOnlyMode:
    return err("cannot advertise in client only mode")
  trace "advertising via waku rendezvous",
    namespace = namespace, ttl = ttl, peers = $peers, peerRecord = $self.getPeerRecord()
  let se = SignedPayload[WakuPeerRecord].init(
    self.switch.peerInfo.privateKey, self.getPeerRecord()
  ).valueOr:
    return err("rendezvous advertisement failed: Failed to sign Waku Peer Record")
  let sprBuff = se.encode().valueOr:
    return err("rendezvous advertisement failed: Wrong Signed Peer Record")

  # rendezvous.advertise expects already opened connections
  # must dial first

  var futs = collect(newSeq):
    for peerId in peers:
      self.peerManager.dialPeer(peerId, self.codec)

  let dialCatch = catch:
    await allFinished(futs)

  if dialCatch.isErr():
    return err("advertise: " & dialCatch.error.msg)

  futs = dialCatch.get()

  let conns = collect(newSeq):
    for fut in futs:
      let catchable = catch:
        fut.read()

      if catchable.isErr():
        warn "a rendezvous dial failed", cause = catchable.error.msg
        continue

      let connOpt = catchable.get()

      let conn = connOpt.valueOr:
        continue

      conn

  try:
    await self.advertise(namespace, ttl, peers, sprBuff)
  except Exception as e:
    return err("rendezvous advertisement failed: " & e.msg)
  finally:
    for conn in conns:
      await conn.close()
  return ok()

proc advertiseAll*(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  if self.clientOnlyMode:
    return err("cannot advertise in client only mode")

  trace "waku rendezvous advertisements started"

  let rpi = self.peerManager.selectPeer(self.codec).valueOr:
    return err("could not get a peer supporting RendezVousCodec")

  let namespace = computeMixNamespace(self.clusterId)

  # Advertise yourself on that peer
  let res = await self.advertise(namespace, @[rpi.peerId])

  trace "waku rendezvous advertisements finished"

  return res

proc requestAll*(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  trace "waku rendezvous requests started"

  let namespace = computeMixNamespace(self.clusterId)

  # Get a random WakuRDV peer
  let rpi = self.peerManager.selectPeer(self.codec).valueOr:
    return err("could not get a peer supporting WakuRendezVousCodec")

  # rendezvous.request expects already opened connections
  # must dial first

  let connOpt =
    try:
      await self.peerManager.dialPeer(rpi.peerId, self.codec)
    except CatchableError as e:
      return err("failed to dial peer: " & e.msg)

  let conn = connOpt.valueOr:
    return err("could not dial peer supporting WakuRendezVousCodec")

  var records: seq[WakuPeerRecord]
  try:
    # Ask for peer records
    records = await rendezvous.request[WakuPeerRecord](
      self, Opt.some(namespace), Opt.some(PeersRequestedCount), Opt.some(@[rpi.peerId])
    )
  except CatchableError as e:
    return err("rendezvous request failed: " & e.msg)
  trace "waku rendezvous request got peers", count = records.len
  for record in records:
    rendezvousPeerFoundTotal.inc()
    if record.mixKey.len == 0 or record.peerId == self.switch.peerInfo.peerId:
      continue
    trace "adding peer from rendezvous",
      peerId = record.peerId, addresses = $record.addresses, mixKey = record.mixKey
    let rInfo = RemotePeerInfo.init(
      record.peerId,
      record.addresses,
      mixPubKey = some(intoCurve25519Key(fromHex(record.mixKey))),
    )
    self.peerManager.addPeer(rInfo)

  await conn.close()
  trace "waku rendezvous initial request finished"

  return ok()

proc periodicRegistration(self: WakuRendezVous) {.async.} =
  info "waku rendezvous periodic registration started",
    interval = self.registrationInterval

  # infinite loop
  while true:
    await sleepAsync(self.registrationInterval)

    (await self.advertiseAll()).isOkOr:
      info "waku rendezvous advertisements failed", error = error

      if self.registrationInterval > MaxRegistrationInterval:
        self.registrationInterval = MaxRegistrationInterval
      else:
        self.registrationInterval += self.registrationInterval

    # Back to normal interval if no errors
    self.registrationInterval = DefaultRegistrationInterval

proc periodicRequests(self: WakuRendezVous) {.async.} =
  info "waku rendezvous periodic requests started", interval = self.requestInterval

  # infinite loop
  while true:
    (await self.requestAll()).isOkOr:
      error "waku rendezvous requests failed", error = error

    await sleepAsync(self.requestInterval)

    # Exponential backoff

#[    TODO: Reevaluate for mix, maybe be aggresive in the start until a sizeable pool is built and then backoff
    self.requestInterval += self.requestInterval

    if self.requestInterval >= 1.days:
      break ]#

proc new*(
    T: type WakuRendezVous,
    switch: Switch,
    peerManager: PeerManager,
    clusterId: uint16,
    getShards: GetShards,
    getCapabilities: GetCapabilities,
    getPeerRecord: GetWakuPeerRecord = nil,
    clientOnlyMode = false,
): Result[T, string] {.raises: [].} =
  let rng = newRng()
  let wrv = T(
    rng: rng,
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](),
    expiredDT: Moment.now() - 1.days,
    sema: newAsyncSemaphore(SemaphoreDefaultSize),
    minDuration: rendezvous.MinimumAcceptedDuration,
    maxDuration: rendezvous.MaximumDuration,
    minTTL: rendezvous.MinimumAcceptedDuration.seconds.uint64,
    maxTTL: rendezvous.MaximumDuration.seconds.uint64,
    peerRecordValidator: checkWakuPeerRecord,
    clientOnlyMode: clientOnlyMode,
  )

  wrv.peerManager = peerManager
  wrv.clusterId = clusterId
  wrv.getShards = getShards
  wrv.getCapabilities = getCapabilities
  wrv.registrationInterval = DefaultRegistrationInterval
  wrv.requestInterval = 10.seconds # TODO: for testing, need to move back to default
  wrv.getPeerRecord = getPeerRecord
  wrv.switch = switch
  wrv.codec = WakuRendezVousCodec

  if not clientOnlyMode:
    proc handleStream(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        let
          buf = await conn.readLp(4096)
          msg = Message.decode(buf).tryGet()
        case msg.msgType
        of MessageType.Register:
          #TODO: override this to store peers registered with us in peerstore with their info as well.
          await wrv.register(conn, msg.register.tryGet(), wrv.getPeerRecord())
        of MessageType.RegisterResponse:
          trace "Got an unexpected Register Response", response = msg.registerResponse
        of MessageType.Unregister:
          wrv.unregister(conn, msg.unregister.tryGet())
        of MessageType.Discover:
          await wrv.discover(conn, msg.discover.tryGet())
        of MessageType.DiscoverResponse:
          trace "Got an unexpected Discover Response", response = msg.discoverResponse
      except CancelledError as exc:
        trace "cancelled rendezvous handler"
        raise exc
      except CatchableError as exc:
        trace "exception in rendezvous handler", description = exc.msg
      finally:
        await conn.close()

    wrv.handler = handleStream

  info "waku rendezvous initialized",
    clusterId = clusterId,
    shards = getShards(),
    capabilities = getCapabilities(),
    wakuPeerRecord = getPeerRecord()

  return ok(wrv)

proc start*(self: WakuRendezVous) {.async: (raises: []).} =
  # Start the parent GenericRendezVous (starts the register deletion loop)
  if not self.clientOnlyMode:
    if self.started:
      warn "waku rendezvous already started"
      return
    try:
      await procCall GenericRendezVous[WakuPeerRecord](self).start()
    except CancelledError as exc:
      error "failed to start GenericRendezVous", cause = exc.msg

    # start registering forever
    self.periodicRegistrationFut = self.periodicRegistration()

  self.periodicRequestFut = self.periodicRequests()

  info "waku rendezvous discovery started"

proc stopWait*(self: WakuRendezVous) {.async: (raises: []).} =
  if not self.periodicRegistrationFut.isNil():
    await self.periodicRegistrationFut.cancelAndWait()

  if not self.periodicRequestFut.isNil():
    await self.periodicRequestFut.cancelAndWait()

  # Stop the parent GenericRendezVous (stops the register deletion loop)
  await GenericRendezVous[WakuPeerRecord](self).stop()

  info "waku rendezvous discovery stopped"
