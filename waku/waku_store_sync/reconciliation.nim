{.push raises: [].}

import
  std/[sequtils, options, packedsets],
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
  ../waku_core/codecs,
  ../waku_core/time,
  ../waku_core/topics/pubsub_topic,
  ../waku_core/message/digest,
  ../waku_core/message/message,
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
  cluster: uint16
  shards: PackedSet[uint16]

  peerManager: PeerManager

  wakuArchive: WakuArchive

  storage: SyncStorage

  # AsyncQueues are used as communication channels between
  # reconciliation and transfer protocols.
  idsRx: AsyncQueue[SyncID]
  localWantsTx: AsyncQueue[PeerId]
  remoteNeedsTx: AsyncQueue[(PeerId, WakuMessageHash)]

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
  trace "message ingress", pubsub_topic = pubsubTopic, msg = msg

  if msg.ephemeral:
    return

  let msgHash = computeMessageHash(pubsubTopic, msg)

  let id = SyncID(time: msg.timestamp, hash: msgHash)

  self.storage.insert(id).isOkOr:
    error "failed to insert new message", msg_hash = msgHash.toHex(), err = error

proc messageIngress*(
    self: SyncReconciliation, msgHash: WakuMessageHash, msg: WakuMessage
) =
  trace "message ingress", msg_hash = msgHash.toHex(), msg = msg

  if msg.ephemeral:
    return

  let id = SyncID(time: msg.timestamp, hash: msgHash)

  self.storage.insert(id).isOkOr:
    error "failed to insert new message", msg_hash = msgHash.toHex(), err = error

proc messageIngress*(self: SyncReconciliation, id: SyncID) =
  trace "message ingress", id = id

  self.storage.insert(id).isOkOr:
    error "failed to insert new message", msg_hash = id.hash.toHex(), err = error

proc processRequest(
    self: SyncReconciliation, conn: Connection
): Future[Result[void, string]] {.async.} =
  var
    roundTrips = 0
    diffs = 0

  # Signal to transfer protocol that this reconciliation is starting
  await self.localWantsTx.addLast(conn.peerId)

  while true:
    let readRes = catch:
      await conn.readLp(int.high)

    let buffer: seq[byte] = readRes.valueOr:
      await conn.close()
      return err("remote " & $conn.peerId & " connection read error: " & error.msg)

    total_bytes_exchanged.inc(buffer.len, labelValues = [Reconciliation, Receiving])

    let recvPayload = RangesData.deltaDecode(buffer).valueOr:
      await conn.close()
      return err("remote " & $conn.peerId & " payload decoding error: " & error)

    roundTrips.inc()

    debug "sync payload received",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = recvPayload

    if recvPayload.ranges.len == 0 or recvPayload.ranges.allIt(it[1] == RangeType.Skip):
      break

    var
      hashToRecv: seq[WakuMessageHash]
      hashToSend: seq[WakuMessageHash]
      sendPayload: RangesData
      rawPayload: seq[byte]

    # Only process the ranges IF the shards and cluster matches
    if self.cluster == recvPayload.cluster and
        recvPayload.shards.toPackedSet() == self.shards:
      sendPayload = self.storage.processPayload(recvPayload, hashToSend, hashToRecv)

      debug "sync payload processed",
        hash_to_send = hashToSend, hash_to_recv = hashToRecv

      sendPayload.cluster = self.cluster
      sendPayload.shards = self.shards.toSeq()

      for hash in hashToSend:
        self.remoteNeedsTx.addLastNoWait((conn.peerId, hash))
        diffs.inc()

      for hash in hashToRecv:
        diffs.inc()

      rawPayload = sendPayload.deltaEncode()

    total_bytes_exchanged.inc(rawPayload.len, labelValues = [Reconciliation, Sending])

    let writeRes = catch:
      await conn.writeLP(rawPayload)

    if writeRes.isErr():
      await conn.close()
      return
        err("remote " & $conn.peerId & " connection write error: " & writeRes.error.msg)

    debug "sync payload sent",
      local = self.peerManager.switch.peerInfo.peerId,
      remote = conn.peerId,
      payload = sendPayload

    if sendPayload.ranges.len == 0 or sendPayload.ranges.allIt(it[1] == RangeType.Skip):
      break

    continue

  # Signal to transfer protocol that this reconciliation is done
  await self.localWantsTx.addLast(conn.peerId)

  reconciliation_roundtrips.observe(roundTrips)
  reconciliation_differences.observe(diffs)

  await conn.close()

  return ok()

proc initiate(
    self: SyncReconciliation, connection: Connection
): Future[Result[void, string]] {.async.} =
  let
    timeRange = calculateTimeRange(self.relayJitter, self.syncRange)
    lower = SyncID(time: timeRange.a, hash: EmptyFingerprint)
    upper = SyncID(time: timeRange.b, hash: FullFingerprint)
    bounds = lower .. upper

    fingerprint = self.storage.computeFingerprint(bounds)
    initPayload = RangesData(
      cluster: self.cluster,
      shards: self.shards.toSeq(),
      ranges: @[(bounds, RangeType.Fingerprint)],
      fingerprints: @[fingerprint],
      itemSets: @[],
    )

  let sendPayload = initPayload.deltaEncode()

  total_bytes_exchanged.inc(sendPayload.len, labelValues = [Reconciliation, Sending])

  let writeRes = catch:
    await connection.writeLP(sendPayload)

  if writeRes.isErr():
    await connection.close()
    return err(
      "remote " & $connection.peerId & " connection write error: " & writeRes.error.msg
    )

  debug "sync payload sent",
    local = self.peerManager.switch.peerInfo.peerId,
    remote = connection.peerId,
    payload = initPayload

  ?await self.processRequest(connection)

  return ok()

proc storeSynchronization*(
    self: SyncReconciliation, peerInfo: Option[RemotePeerInfo] = none(RemotePeerInfo)
): Future[Result[void, string]] {.async.} =
  let peer = peerInfo.valueOr:
    self.peerManager.selectPeer(WakuReconciliationCodec).valueOr:
      return err("no suitable peer found for sync")

  let connOpt = await self.peerManager.dialPeer(peer, WakuReconciliationCodec)

  let conn: Connection = connOpt.valueOr:
    return err("fail to dial remote " & $peer.peerId)

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
): Future[Result[seq[SyncID], string]] {.async.} =
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

  var ids = newSeqOfCap[SyncID](DefaultStorageCap)

  # we assume IDs are in order

  while true:
    let response = (await wakuArchive.findMessages(query)).valueOr:
      return err("archive retrival failed: " & $error)

    for i in 0 ..< response.hashes.len:
      let hash = response.hashes[i]
      let msg = response.messages[i]

      ids.add(SyncID(time: msg.timestamp, hash: hash))

    if response.cursor.isNone():
      break

    query.cursor = response.cursor

  debug "initial storage filling done", elements = ids.len

  return ok(ids)

proc new*(
    T: type SyncReconciliation,
    cluster: uint16,
    shards: seq[uint16],
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    syncRange: timer.Duration = DefaultSyncRange,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: timer.Duration = DefaultGossipSubJitter,
    idsRx: AsyncQueue[SyncID],
    localWantsTx: AsyncQueue[PeerId],
    remoteNeedsTx: AsyncQueue[(PeerId, WakuMessageHash)],
): Future[Result[T, string]] {.async.} =
  let res = await initFillStorage(syncRange, wakuArchive)
  let storage =
    if res.isErr():
      warn "will not sync messages before this point in time", error = res.error
      SeqStorage.new(DefaultStorageCap)
    else:
      SeqStorage.new(res.get())

  var sync = SyncReconciliation(
    cluster: cluster,
    shards: shards.toPackedSet(),
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
  sync.codec = WakuReconciliationCodec

  info "Store Reconciliation protocol initialized",
    sync_range = syncRange, sync_interval = syncInterval, relay_jitter = relayJitter

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

    total_messages_cached.set(self.storage.length())

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

proc stop*(self: SyncReconciliation) =
  if self.syncInterval > ZeroDuration:
    self.periodicSyncFut.cancelSoon()

  if self.syncInterval > ZeroDuration:
    self.periodicPruneFut.cancelSoon()

  self.idsReceiverFut.cancelSoon()

  info "Store Sync Reconciliation protocol stopped"
