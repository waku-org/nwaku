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
  ./raw_bindings,
  ./common,
  ./session

logScope:
  topics = "waku sync"

type WakuSync* = ref object of LPProtocol
  storage: NegentropyStorage
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

proc storageSize*(self: WakuSync): int =
  self.storage.len

proc ingessMessage*(self: WakuSync, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if msg.ephemeral:
    return

  let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic, msg)

  trace "inserting message into waku sync storage ",
    msg_hash = msgHash.to0xHex(), timestamp = msg.timestamp

  if self.storage.insert(msg.timestamp, msgHash).isErr():
    error "failed to insert message ", msg_hash = msgHash.to0xHex()

proc calculateRange(jitter: Duration, syncRange: Duration = 1.hours): (int64, int64) =
  var now = getNowInNanosecondTime()

  # Because of message jitter inherent to Relay protocol
  now -= jitter.nanos

  let range = syncRange.nanos

  let start = now - range
  let `end` = now

  return (start, `end`)

proc request(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let (start, `end`) = calculateRange(self.relayJitter)

  let initialized =
    ?clientInitialize(self.storage, conn, self.maxFrameSize, start, `end`)

  debug "sync session initialized",
    client = self.peerManager.switch.peerInfo.peerId,
    server = conn.peerId,
    frameSize = self.maxFrameSize,
    timeStart = start,
    timeEnd = `end`

  var hashes: seq[WakuMessageHash]
  var reconciled = initialized

  while true:
    let sent = ?await reconciled.send()

    trace "sync payload sent",
      client = self.peerManager.switch.peerInfo.peerId,
      server = conn.peerId,
      payload = reconciled.payload

    let received = ?await sent.listenBack()

    trace "sync payload received",
      client = self.peerManager.switch.peerInfo.peerId,
      server = conn.peerId,
      payload = received.payload

    reconciled = (?received.clientReconcile(hashes)).valueOr:
      let completed = error # Result[Reconciled, Completed]

      ?await completed.clientTerminate()

      debug "sync session ended gracefully",
        client = self.peerManager.switch.peerInfo.peerId, server = conn.peerId

      return ok(hashes)

proc sync*(
    self: WakuSync, peerInfo: Option[RemotePeerInfo] = none(RemotePeerInfo)
): Future[Result[(seq[WakuMessageHash], RemotePeerInfo), string]] {.async, gcsafe.} =
  let peer =
    if peerInfo.isSome():
      peerInfo.get()
    else:
      let peer: RemotePeerInfo = self.peerManager.selectPeer(WakuSyncCodec).valueOr:
        return err("No suitable peer found for sync")

      peer

  let connOpt = await self.peerManager.dialPeer(peer, WakuSyncCodec)

  let conn: Connection = connOpt.valueOr:
    return err("Cannot establish sync connection")

  let hashes: seq[WakuMessageHash] = (await self.request(conn)).valueOr:
    debug "sync session ended",
      server = self.peerManager.switch.peerInfo.peerId, client = conn.peerId, error

    return err("Sync request error: " & error)

  return ok((hashes, peer))

proc handleLoop(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async.} =
  let (start, `end`) = calculateRange(self.relayJitter)

  let initialized =
    ?serverInitialize(self.storage, conn, self.maxFrameSize, start, `end`)

  var sent = initialized

  while true:
    let received = ?await sent.listenBack()

    trace "sync payload received",
      server = self.peerManager.switch.peerInfo.peerId,
      client = conn.peerId,
      payload = received.payload

    let reconciled = (?received.serverReconcile()).valueOr:
      let completed = error # Result[Reconciled, Completed]

      let hashes = await completed.serverTerminate()

      return ok(hashes)

    sent = ?await reconciled.send()

    trace "sync payload sent",
      server = self.peerManager.switch.peerInfo.peerId,
      client = conn.peerId,
      payload = reconciled.payload

proc initProtocolHandler(self: WakuSync) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    debug "sync session requested",
      server = self.peerManager.switch.peerInfo.peerId, client = conn.peerId

    let hashes = (await self.handleLoop(conn)).valueOr:
      debug "sync session ended",
        server = self.peerManager.switch.peerInfo.peerId, client = conn.peerId, error

      #TODO send error code and desc to client
      return

    if hashes.len > 0 and self.transferCallBack.isSome():
      let callback = self.transferCallBack.get()

      (await callback(hashes, conn.peerId)).isOkOr:
        error "transfer callback failed", error = $error

    debug "sync session ended gracefully",
      server = self.peerManager.switch.peerInfo.peerId, client = conn.peerId

  self.handler = handle
  self.codec = WakuSyncCodec

proc initPruningHandler(self: WakuSync, wakuArchive: WakuArchive) =
  if wakuArchive.isNil():
    return

  self.pruneCallBack = some(
    proc(
        pruneStart: Timestamp, pruneStop: Timestamp, cursor: Option[WakuMessageHash]
    ): Future[
        Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
    ] {.async: (raises: []), closure.} =
      let archiveCursor =
        if cursor.isSome():
          some(ArchiveCursor(hash: cursor.get()))
        else:
          none(ArchiveCursor)

      let query = ArchiveQuery(
        includeData: true,
        cursor: archiveCursor,
        startTime: some(pruneStart),
        endTime: some(pruneStop),
        pageSize: 100,
      )

      let catchable = catch:
        await wakuArchive.findMessages(query)

      if catchable.isErr():
        return err("archive error: " & catchable.error.msg)

      let res = catchable.get()
      let response = res.valueOr:
        return err("archive error: " & $error)

      let elements = collect(newSeq):
        for (hash, msg) in response.hashes.zip(response.messages):
          (hash, msg.timestamp)

      let cursor =
        if response.cursor.isNone():
          none(WakuMessageHash)
        else:
          some(response.cursor.get().hash)

      return ok((elements, cursor))
  )

proc initTransferHandler(
    self: WakuSync, wakuArchive: WakuArchive, wakuStoreClient: WakuStoreClient
) =
  if wakuArchive.isNil() or wakuStoreClient.isNil():
    return

  self.transferCallBack = some(
    proc(
        hashes: seq[WakuMessageHash], peerId: PeerId
    ): Future[Result[void, string]] {.async: (raises: []), closure.} =
      var query = StoreQueryRequest()
      query.includeData = true
      query.messageHashes = hashes
      query.paginationLimit = some(uint64(100))

      while true:
        let catchable = catch:
          await wakuStoreClient.query(query, peerId)

        if catchable.isErr():
          return err("store client error: " & catchable.error.msg)

        let res = catchable.get()
        let response = res.valueOr:
          return err("store client error: " & $error)

        query.paginationCursor = response.paginationCursor

        for kv in response.messages:
          let handleRes = catch:
            await wakuArchive.handleMessage(kv.pubsubTopic.get(), kv.message.get())

          if handleRes.isErr():
            error "message transfer failed", error = handleRes.error.msg
            # Messages can be synced next time since they are not added to storage yet.
            continue

          self.ingessMessage(kv.pubsubTopic.get(), kv.message.get())

        if query.paginationCursor.isNone():
          break

      return ok()
  )

proc initFillStorage(
    self: WakuSync, wakuArchive: WakuArchive
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
      self.ingessMessage(topic, msg)

    if response.cursor.isNone():
      break

    query.cursor = response.cursor

  return ok()

proc new*(
    T: type WakuSync,
    peerManager: PeerManager,
    maxFrameSize: int = DefaultMaxFrameSize,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: Duration = DefaultGossipSubJitter,
    pruning: bool,
    wakuArchive: WakuArchive,
    wakuStoreClient: WakuStoreClient,
): Future[Result[T, string]] {.async.} =
  let storage = NegentropyStorage.new().valueOr:
    return err("negentropy storage creation failed")

  let sync = WakuSync(
    storage: storage,
    peerManager: peerManager,
    maxFrameSize: maxFrameSize,
    syncInterval: syncInterval,
    relayJitter: relayJitter,
    pruneOffset: syncInterval div 2,
  )

  sync.initProtocolHandler()

  if pruning:
    sync.initPruningHandler(wakuArchive)

  sync.initTransferHandler(wakuArchive, wakuStoreClient)

  let res = await sync.initFillStorage(wakuArchive)
  if res.isErr():
    return err("initial storage filling error: " & res.error)

  info "WakuSync protocol initialized"

  return ok(sync)

proc periodicSync(self: WakuSync, callback: TransferCallback) {.async.} =
  debug "periodic sync initialized", interval = $self.syncInterval

  while true:
    await sleepAsync(self.syncInterval)

    debug "periodic sync started"

    var
      hashes: seq[WakuMessageHash]
      peer: RemotePeerInfo
      tries = 3

    while true:
      let res = (await self.sync()).valueOr:
        error "sync failed", error = $error
        if tries > 0:
          tries -= 1
          await sleepAsync(30.seconds)
          continue
        else:
          break

      hashes = res[0]
      peer = res[1]
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

proc periodicPrune(self: WakuSync, callback: PruneCallback) {.async.} =
  debug "periodic prune initialized", interval = $self.syncInterval

  await sleepAsync(self.syncInterval)

  var pruneStop = getNowInNanosecondTime()

  while true:
    await sleepAsync(self.syncInterval)

    debug "periodic prune started",
      startTime = self.pruneStart - self.pruneOffset.nanos,
      endTime = pruneStop,
      storageSize = self.storage.len

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
        self.storage.erase(timestamp, hash).isOkOr:
          error "storage erase failed",
            timestamp = timestamp, msg_hash = hash, error = $error
          continue

      if cursor.isNone():
        break

    self.pruneStart = pruneStop
    pruneStop = getNowInNanosecondTime()

    debug "periodic prune done", storageSize = self.storage.len

proc start*(self: WakuSync) =
  self.started = true
  self.pruneStart = getNowInNanosecondTime()

  if self.transferCallBack.isSome() and self.syncInterval > ZeroDuration:
    self.periodicSyncFut = self.periodicSync(self.transferCallBack.get())

  if self.pruneCallBack.isSome() and self.syncInterval > ZeroDuration:
    self.periodicPruneFut = self.periodicPrune(self.pruneCallBack.get())

  info "WakuSync protocol started"

proc stopWait*(self: WakuSync) {.async.} =
  if self.transferCallBack.isSome() and self.syncInterval > ZeroDuration:
    await self.periodicSyncFut.cancelAndWait()

  if self.pruneCallBack.isSome() and self.syncInterval > ZeroDuration:
    await self.periodicPruneFut.cancelAndWait()

  info "WakuSync protocol stopped"
