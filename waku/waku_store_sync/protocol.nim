when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, sugar, sequtils],
  stew/[results, byteutils],
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../common/nimchronos,
  ../common/enr,
  ../waku_core,
  ../waku_archive,
  ../waku_store/[client, common],
  ../waku_enr,
  ../node/peer_manager/peer_manager,
  ../waku_sync

logScope:
  topics = "waku store sync"

type WakuStoreSync* = ref object of LPProtocol
  peerManager: PeerManager

  maxFrameSize: int

  syncInterval: timer.Duration # Time between each syncronisation attempt
  relayJitter: Duration # Time delay until all messages are mostly received network wide
  transferCallBack: Option[TransferCallback] # Callback for message transfer.

  pruneCallBack: Option[PruneCallBack] # Callback with the result of the archive query
  pruneStart: Timestamp # Last pruning start timestamp
  pruneOffset: timer.Duration # Offset to prune a bit more than necessary. 

  periodicSyncFut: Future[void]
  periodicPruneFut: Future[void]

proc calculateRange(jitter: Duration, syncRange: Duration = 1.hours): (int64, int64) =
  var now = getNowInNanosecondTime()

  # Because of message jitter inherent to Relay protocol
  now -= jitter.nanos

  let range = syncRange.nanos

  let start = now - range
  let `end` = now

  return (start, `end`)

proc fillSyncStorage(
    self: WakuStoreSync, wakuSync: WakuSync, wakuArchive: WakuArchive
): Future[Result[void, string]] {.async.} =
  if wakuArchive.isNil():
    return ok()

  let endTime = getNowInNanosecondTime()
  let starTime = endTime - self.syncInterval.nanos

  var query = ArchiveQuery(
    includeData: true,
    cursor: none(ArchiveCursor),
    startTime: some(starTime),
    endTime: some(endTime),
    pageSize: 100,
  )

  while true:
    let response = (await wakuArchive.findMessages(query)).valueOr:
      return err($error)

    for (topic, msg) in response.topics.zip(response.messages):
      wakuSync.ingessMessage(topic, msg)

    if response.cursor.isNone():
      break

    query.cursor = response.cursor

  return ok()

# Either create a callback in waku sync or move this logic back to it
proc periodicSync(
    self: WakuStoreSync, wakuSync: WakuSync, callback: TransferCallback
) {.async.} =
  debug "periodic sync initialized", interval = $self.syncInterval

  while true:
    await sleepAsync(self.syncInterval)

    debug "periodic sync started"

    let peer: RemotePeerInfo = self.peerManager.selectPeer(WakuSyncCodec).valueOr:
      error "No suitable peer found for sync"
      return

    let connOpt = await self.peerManager.dialPeer(peer, WakuSyncCodec)

    let conn: Connection = connOpt.valueOr:
      error "Cannot establish sync connection"
      return

    let (rangeStart, rangeEnd) = calculateRange(self.relayJitter, self.syncInterval)

    var
      hashes: seq[WakuMessageHash]
      tries = 3

    while true:
      hashes = (await wakuSync.request(conn, self.maxFrameSize, rangeStart, rangeEnd)).valueOr:
        error "sync failed", error = $error
        if tries > 0:
          tries -= 1
          await sleepAsync(30.seconds)
          continue
        else:
          break

      break

    if hashes.len > 0:
      tries = 3
      while true:
        (await callback(hashes, peer.peerId)).isOkOr:
          error "transfer callback failed", error = $error
          if tries > 0:
            tries -= 1
            await sleepAsync(30.seconds)
            continue
          else:
            break

        break

    debug "periodic sync done", hashSynced = hashes.len

# Same here
proc periodicPrune(
    self: WakuStoreSync, wakuSync: WakuSync, callback: PruneCallback
) {.async.} =
  debug "periodic prune initialized", interval = $self.syncInterval

  await sleepAsync(self.syncInterval)

  var pruneStop = getNowInNanosecondTime()

  while true:
    await sleepAsync(self.syncInterval)

    debug "periodic prune started",
      startTime = self.pruneStart - self.pruneOffset.nanos,
      endTime = pruneStop,
      storageSize = wakuSync.storageSize()

    var (elements, cursor) =
      (newSeq[(WakuMessageHash, Timestamp)](0), none(WakuMessageHash))

    var tries = 3
    while true:
      (elements, cursor) = (
        await callback(self.pruneStart - self.pruneOffset.nanos, pruneStop, cursor)
      ).valueOr:
        error "pruning callback failed", error = $error
        if tries > 0:
          tries -= 1
          await sleepAsync(30.seconds)
          continue
        else:
          break

      if elements.len == 0:
        break

      for (hash, timestamp) in elements:
        wakuSync.eraseMessage(timestamp, hash).isOkOr:
          error "storage erase failed",
            timestamp = timestamp, msg_hash = hash, error = $error
          continue

      if cursor.isNone():
        break

    self.pruneStart = pruneStop
    pruneStop = getNowInNanosecondTime()

    debug "periodic prune done", storageSize = wakuSync.storageSize()

proc start*(self: WakuStoreSync) =
  self.started = true
  self.pruneStart = getNowInNanosecondTime()

  if self.transferCallBack.isSome() and self.syncInterval > ZeroDuration:
    self.periodicSyncFut = self.periodicSync(self.transferCallBack.get())

  if self.pruneCallBack.isSome() and self.syncInterval > ZeroDuration:
    self.periodicPruneFut = self.periodicPrune(self.pruneCallBack.get())

  info "WakuStoreSync protocol started"

proc stopWait*(self: WakuStoreSync) {.async.} =
  if self.transferCallBack.isSome() and self.syncInterval > ZeroDuration:
    await self.periodicSyncFut.cancelAndWait()

  if self.pruneCallBack.isSome() and self.syncInterval > ZeroDuration:
    await self.periodicPruneFut.cancelAndWait()

  info "WakuStoreSync protocol stopped"
