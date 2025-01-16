{.push raises: [].}

import
  std/sequtils,
  stew/byteutils,
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/utility,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../common/nimchronos,
  ../common/protobuf,
  ../common/paging,
  ../waku_enr,
  ../waku_core,
  ../node/peer_manager/peer_manager,
  ../waku_archive,
  ./common,
  ./codec,
  ./storage/storage,
  ./storage/seq_storage,
  ./storage/range_processing,
  ./protocols_metrics

logScope:
  topics = "waku reconciliation"

const DefaultStorageCap = 50_000

type SyncReconciliation* = ref object of LPProtocol
  peerManager: PeerManager

  wakuArchive: WakuArchive

  storage: SyncStorage

  # Receive IDs from transfer protocol for storage
  idsRx: AsyncQueue[ID]

  # Send Hashes to transfer protocol for reception
  localWantsTx: AsyncQueue[(PeerId, Fingerprint)]

  # Send Hashes to transfer protocol for transmission
  remoteNeedsTx: AsyncQueue[(PeerId, Fingerprint)]

  # params
  syncInterval: timer.Duration # Time between each synchronization attempt
  syncRange: timer.Duration # Amount of time in the past to sync
  relayJitter: Duration # Amount of time since the present to ignore when syncing

  # futures
  periodicSyncFut: Future[void]
  periodicPruneFut: Future[void]
  idsReceiverFut: Future[void]

proc messageIngress*(
    self: SyncReconciliation, pubsubTopic: PubsubTopic, msg: WakuMessage
) =
  let msgHash = computeMessageHash(pubsubTopic, msg)

  let id = ID(time: msg.timestamp, fingerprint: msgHash)

  self.storage.insert(id).isOkOr:
    error "failed to insert new message", msg_hash = msgHash.toHex(), err = error

proc messageIngress*(
    self: SyncReconciliation, msgHash: WakuMessageHash, msg: WakuMessage
) =
  let id = ID(time: msg.timestamp, fingerprint: msgHash)

  self.storage.insert(id).isOkOr:
    error "failed to insert new message", msg_hash = msgHash.toHex(), err = error

proc messageIngress*(self: SyncReconciliation, id: ID) =
  self.storage.insert(id).isOkOr:
    error "failed to insert new message", msg_hash = id.fingerprint.toHex(), err = error

proc processRequest(
    self: SyncReconciliation, conn: Connection
): Future[Result[void, string]] {.async.} =
  var roundTrips = 0

  while true:
    let readRes = catch:
      await conn.readLp(int.high)

    let buffer: seq[byte] = readRes.valueOr:
      return err("connection read error: " & error.msg)

    total_bytes_exchanged.observe(buffer.len, labelValues = [ReconRecv])

    let recvPayload = SyncPayload.deltaDecode(buffer)

    roundTrips.inc()

    trace "sync payload received",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = recvPayload

    if recvPayload.ranges.len == 0 or
        recvPayload.ranges.allIt(it[1] == RangeType.skipRange):
      break

    var
      hashToRecv: seq[Fingerprint]
      hashToSend: seq[Fingerprint]

    let sendPayload = self.storage.processPayload(recvPayload, hashToSend, hashToRecv)

    for hash in hashToSend:
      await self.remoteNeedsTx.addLast((conn.peerId, hash))

    for hash in hashToRecv:
      await self.wantstx.addLast((conn.peerId, hash))

    let rawPayload = sendPayload.deltaEncode()

    total_bytes_exchanged.observe(rawPayload.len, labelValues = [ReconSend])

    let writeRes = catch:
      await conn.writeLP(rawPayload)

    if writeRes.isErr():
      return err("connection write error: " & writeRes.error.msg)

    trace "sync payload sent",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = sendPayload

    if sendPayload.ranges.len == 0 or
        sendPayload.ranges.allIt(it[1] == RangeType.skipRange):
      break

    continue

  reconciliation_roundtrips.observe(roundTrips)

  await conn.close()

  return ok()

proc initiate(
    self: SyncReconciliation, connection: Connection
): Future[Result[void, string]] {.async.} =
  let
    timeRange = calculateTimeRange(self.relayJitter, self.syncRange)
    lower = ID(time: timeRange.a, fingerprint: EmptyFingerprint)
    upper = ID(time: timeRange.b, fingerprint: FullFingerprint)
    bounds = lower .. upper

    fingerprint = self.storage.fingerprinting(bounds)
    initPayload = SyncPayload(
      ranges: @[(bounds, fingerprintRange)], fingerprints: @[fingerprint], itemSets: @[]
    )

  let sendPayload = initPayload.deltaEncode()

  total_bytes_exchanged.observe(sendPayload.len, labelValues = [ReconSend])

  let writeRes = catch:
    await connection.writeLP(sendPayload)

  if writeRes.isErr():
    return err("connection write error: " & writeRes.error.msg)

  trace "sync payload sent",
    local = self.peerManager.switch.peerInfo.peerId,
    remote = connection.peerId,
    payload = sendPayload

  ?await self.processRequest(connection)

  return ok()

proc storeSynchronization*(
    self: SyncReconciliation, peerInfo: Option[RemotePeerInfo] = none(RemotePeerInfo)
): Future[Result[void, string]] {.async.} =
  let peer = peerInfo.valueOr:
    self.peerManager.selectPeer(SyncReconciliationCodec).valueOr:
      return err("no suitable peer found for sync")

  let connOpt = await self.peerManager.dialPeer(peer, SyncReconciliationCodec)

  let conn: Connection = connOpt.valueOr:
    return err("cannot establish sync connection")

  debug "sync session initialized",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  (await self.initiate(conn)).isOkOr:
    error "sync session failed",
      local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId, err = error

    return err("sync request error: " & error)

  debug "sync session ended gracefully",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  return ok()

proc initFillStorage(
    syncRange: timer.Duration, wakuArchive: WakuArchive
): Future[Result[seq[ID], string]] {.async.} =
  if wakuArchive.isNil():
    return err("waku archive unavailable")

  let endTime = getNowInNanosecondTime()
  let starTime = endTime - syncRange.nanos

  #TODO special query for only timestap and hash ???

  var query = ArchiveQuery(
    includeData: true,
    cursor: none(ArchiveCursor),
    startTime: some(starTime),
    endTime: some(endTime),
    pageSize: 100,
    direction: PagingDirection.FORWARD,
  )

  debug "initial storage filling started"

  var ids = newSeq[ID](DefaultStorageCap)

  # we assume IDs are in order

  while true:
    let response = (await wakuArchive.findMessages(query)).valueOr:
      return err("archive retrival failed: " & $error)

    for i in 0 ..< response.hashes.len:
      let hash = response.hashes[i]
      let msg = response.messages[i]

      ids.add(ID(time: msg.timestamp, fingerprint: hash))

    if response.cursor.isNone():
      break

    query.cursor = response.cursor

  debug "initial storage filling done", elements = ids.len

  return ok(ids)

proc new*(
    T: type SyncReconciliation,
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    syncRange: timer.Duration = DefaultSyncRange,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: timer.Duration = DefaultGossipSubJitter,
    idsRx: AsyncQueue[ID],
    localWantsTx: AsyncQueue[(PeerId, Fingerprint)],
    remoteNeedsTx: AsyncQueue[(PeerId, Fingerprint)],
): Future[Result[T, string]] {.async.} =
  let res = await initFillStorage(syncRange, wakuArchive)
  let storage =
    if res.isErr():
      warn "will not sync messages before this point in time", error = res.error
      SeqStorage.new(DefaultStorageCap)
    else:
      SeqStorage.new(res.get())

  var sync = SyncReconciliation(
    peerManager: peerManager,
    storage: storage,
    syncRange: syncRange,
    syncInterval: syncInterval,
    relayJitter: relayJitter,
    idsRx: idsRx,
    localWantsTx: localWantsTx,
    remoteNeedsTx: remoteNeedsTx,
  )

  let handler = proc(conn: Connection, proto: string) {.async, closure.} =
    (await sync.processRequest(conn)).isOkOr:
      error "request processing error", error = error

    return

  sync.handler = handler
  sync.codec = SyncReconciliationCodec

  info "Store Reconciliation protocol initialized"

  return ok(sync)

proc periodicSync(self: SyncReconciliation) {.async.} =
  debug "periodic sync initialized", interval = $self.syncInterval

  while true: # infinite loop
    await sleepAsync(self.syncInterval)

    debug "periodic sync started"

    (await self.storeSynchronization()).isOkOr:
      error "periodic sync failed", err = error
      continue

    debug "periodic sync done"

proc periodicPrune(self: SyncReconciliation) {.async.} =
  debug "periodic prune initialized", interval = $self.syncInterval

  # preventing sync and prune loops of happening at the same time.
  await sleepAsync((self.syncInterval div 2))

  while true: # infinite loop
    await sleepAsync(self.syncInterval)

    debug "periodic prune started"

    let time = getNowInNanosecondTime() - self.syncRange.nanos

    let count = self.storage.prune(time)

    debug "periodic prune done", elements_pruned = count

proc idsReceiverLoop(self: SyncReconciliation) {.async.} =
  while true: # infinite loop
    let id = await self.idsRx.popfirst()

    self.messageIngress(id)

proc start*(self: SyncReconciliation) =
  if self.started:
    return

  self.started = true

  if self.syncInterval > ZeroDuration:
    self.periodicSyncFut = self.periodicSync()

  if self.syncInterval > ZeroDuration:
    self.periodicPruneFut = self.periodicPrune()

  self.idsReceiverFut = self.idsReceiverLoop()

  info "Store Sync Reconciliation protocol started"

proc stopWait*(self: SyncReconciliation) {.async.} =
  if self.syncInterval > ZeroDuration:
    await self.periodicSyncFut.cancelAndWait()

  if self.syncInterval > ZeroDuration:
    await self.periodicPruneFut.cancelAndWait()

  await self.idsReceiverFut.cancelAndWait()

  info "Store Sync Reconciliation protocol stopped"
