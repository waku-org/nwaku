{.push raises: [].}

import
  std/[options, sugar, sequtils],
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
  maxFrameSize: int # Negentropy param to limit the size of payloads

  peerManager: PeerManager

  syncInterval: timer.Duration # Time between each syncronisation attempt
  syncRange: timer.Duration # Amount of time in the past to sync
  relayJitter: Duration # Amount of time since the present to ignore when syncing
  transferCallBack: Option[TransferCallback] # Callback for message transfers.

  pruneCallBack: Option[PruneCallBack] # Callback with the result of the archive query
  pruneStart: Timestamp # Last pruning start timestamp
  pruneOffset: timer.Duration # Offset to prune a bit more than necessary. 

  periodicSyncFut: Future[void]
  periodicPruneFut: Future[void]

proc storageSize*(self: WakuSync): int =
  self.storage.len

proc messageIngress*(self: WakuSync, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if msg.ephemeral:
    return

  let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic, msg)

  trace "inserting message into waku sync storage ",
    msg_hash = msgHash.to0xHex(), timestamp = msg.timestamp

  self.storage.insert(msg.timestamp, msgHash).isOkOr:
    error "failed to insert message ", msg_hash = msgHash.to0xHex(), error = $error

proc messageIngress*(
    self: WakuSync, pubsubTopic: PubsubTopic, msgHash: WakuMessageHash, msg: WakuMessage
) =
  if msg.ephemeral:
    return

  trace "inserting message into waku sync storage ",
    msg_hash = msgHash.to0xHex(), timestamp = msg.timestamp

  if self.storage.insert(msg.timestamp, msgHash).isErr():
    error "failed to insert message ", msg_hash = msgHash.to0xHex()

proc calculateRange(
    jitter: Duration = 20.seconds, syncRange: Duration = 1.hours
): (int64, int64) =
  ## Calculates the start and end time of a sync session

  var now = getNowInNanosecondTime()

  # Because of message jitter inherent to Relay protocol
  now -= jitter.nanos

  let syncRange = syncRange.nanos

  let syncStart = now - syncRange
  let syncEnd = now

  return (syncStart, syncEnd)

proc request(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async.} =
  let (syncStart, syncEnd) = calculateRange(self.relayJitter)

  let initialized =
    ?clientInitialize(self.storage, conn, self.maxFrameSize, syncStart, syncEnd)

  debug "sync session initialized",
    client = self.peerManager.switch.peerInfo.peerId,
    server = conn.peerId,
    frameSize = self.maxFrameSize,
    timeStart = syncStart,
    timeEnd = syncEnd

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

    continue

proc storeSynchronization*(
    self: WakuSync, peerInfo: Option[RemotePeerInfo] = none(RemotePeerInfo)
): Future[Result[(seq[WakuMessageHash], RemotePeerInfo), string]] {.async.} =
  let peer = peerInfo.valueOr:
    self.peerManager.selectPeer(WakuSyncCodec).valueOr:
      return err("No suitable peer found for sync")

  let connOpt = await self.peerManager.dialPeer(peer, WakuSyncCodec)

  let conn: Connection = connOpt.valueOr:
    return err("Cannot establish sync connection")

  let hashes: seq[WakuMessageHash] = (await self.request(conn)).valueOr:
    error "sync session ended",
      server = self.peerManager.switch.peerInfo.peerId, client = conn.peerId, error

    return err("Sync request error: " & error)

  return ok((hashes, peer))

proc handleSyncSession(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async.} =
  let (syncStart, syncEnd) = calculateRange(self.relayJitter)

  let initialized =
    ?serverInitialize(self.storage, conn, self.maxFrameSize, syncStart, syncEnd)

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

    continue

proc initProtocolHandler(self: WakuSync) =
  proc handle(conn: Connection, proto: string) {.async, closure.} =
    debug "sync session requested",
      server = self.peerManager.switch.peerInfo.peerId, client = conn.peerId

    let hashes = (await self.handleSyncSession(conn)).valueOr:
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

proc createPruneCallback(
    self: WakuSync, wakuArchive: WakuArchive
): Result[PruneCallBack, string] =
  if wakuArchive.isNil():
    return err ("waku archive unavailable")

  let callback: PruneCallback = proc(
      pruneStart: Timestamp, pruneStop: Timestamp, cursor: Option[WakuMessageHash]
  ): Future[
      Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
  ] {.async: (raises: []), closure.} =
    let archiveCursor =
      if cursor.isSome():
        some(cursor.get())
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

    let cursor = response.cursor

    return ok((elements, cursor))

  return ok(callback)

proc createTransferCallback(
    self: WakuSync, wakuArchive: WakuArchive, wakuStoreClient: WakuStoreClient
): Result[TransferCallback, string] =
  if wakuArchive.isNil():
    return err("waku archive unavailable")

  if wakuStoreClient.isNil():
    return err("waku store client unavailable")

  let callback: TransferCallback = proc(
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

        self.messageIngress(kv.pubsubTopic.get(), kv.messageHash, kv.message.get())

      if query.paginationCursor.isNone():
        break

    return ok()

  return ok(callback)

proc initFillStorage(
    self: WakuSync, wakuArchive: WakuArchive
): Future[Result[void, string]] {.async.} =
  if wakuArchive.isNil():
    return err("waku archive unavailable")

  let endTime = getNowInNanosecondTime()
  let starTime = endTime - self.syncRange.nanos

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

    for i in 0 ..< response.hashes.len:
      let hash = response.hashes[i]
      let topic = response.topics[i]
      let msg = response.messages[i]

      self.messageIngress(topic, hash, msg)

    if response.cursor.isNone():
      break

    query.cursor = response.cursor

  return ok()

proc new*(
    T: type WakuSync,
    peerManager: PeerManager,
    maxFrameSize: int = DefaultMaxFrameSize,
    syncRange: timer.Duration = DefaultSyncRange,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: Duration = DefaultGossipSubJitter,
    wakuArchive: WakuArchive,
    wakuStoreClient: WakuStoreClient,
    pruneCallback: Option[PruneCallback] = none(PruneCallback),
    transferCallback: Option[TransferCallback] = none(TransferCallback),
): Future[Result[T, string]] {.async.} =
  let storage = NegentropyStorage.new().valueOr:
    return err("negentropy storage creation failed")

  var sync = WakuSync(
    storage: storage,
    peerManager: peerManager,
    maxFrameSize: maxFrameSize,
    syncInterval: syncInterval,
    syncRange: syncRange,
    relayJitter: relayJitter,
    pruneOffset: syncInterval div 100,
  )

  sync.initProtocolHandler()

  sync.pruneCallBack = pruneCallback

  if sync.pruneCallBack.isNone():
    let res = sync.createPruneCallback(wakuArchive)

    if res.isErr():
      error "pruning callback creation error", error = res.error
    else:
      sync.pruneCallBack = some(res.get())

  sync.transferCallBack = transferCallback

  if sync.transferCallBack.isNone():
    let res = sync.createTransferCallback(wakuArchive, wakuStoreClient)

    if res.isErr():
      error "transfer callback creation error", error = res.error
    else:
      sync.transferCallBack = some(res.get())

  let res = await sync.initFillStorage(wakuArchive)
  if res.isErr():
    warn "will not sync messages before this point in time", error = res.error

  info "WakuSync protocol initialized"

  return ok(sync)

proc periodicSync(self: WakuSync, callback: TransferCallback) {.async.} =
  debug "periodic sync initialized", interval = $self.syncInterval

  while true: # infinite loop
    await sleepAsync(self.syncInterval)

    debug "periodic sync started"

    var
      hashes: seq[WakuMessageHash]
      peer: RemotePeerInfo
      tries = 3

    while true:
      let res = (await self.storeSynchronization()).valueOr:
        # we either try again or log an error and break
        if tries > 0:
          tries -= 1
          await sleepAsync(RetryDelay)
          continue
        else:
          error "sync failed", error = $error
          break

      hashes = res[0]
      peer = res[1]
      break

    if hashes.len > 0:
      tries = 3
      while true:
        (await callback(hashes, peer.peerId)).isOkOr:
          # we either try again or log an error and break
          if tries > 0:
            tries -= 1
            await sleepAsync(RetryDelay)
            continue
          else:
            error "transfer callback failed", error = $error
            break

        break

    debug "periodic sync done", hashSynced = hashes.len

    continue

proc periodicPrune(self: WakuSync, callback: PruneCallback) {.async.} =
  debug "periodic prune initialized", interval = $self.syncInterval

  # Default T minus 60m
  self.pruneStart = getNowInNanosecondTime() - self.syncRange.nanos

  await sleepAsync(self.syncInterval)

  # Default T minus 55m
  var pruneStop = getNowInNanosecondTime() - self.syncRange.nanos

  while true: # infinite loop
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
        # we either try again or log an error and break
        if tries > 0:
          tries -= 1
          await sleepAsync(RetryDelay)
          continue
        else:
          error "pruning callback failed", error = $error
          break

      if elements.len == 0:
        # no elements to remove, stop
        break

      for (hash, timestamp) in elements:
        self.storage.erase(timestamp, hash).isOkOr:
          error "storage erase failed",
            timestamp = timestamp, msg_hash = hash.to0xHex(), error = $error
          continue

      if cursor.isNone():
        # no more pages, stop
        break

    self.pruneStart = pruneStop
    pruneStop = getNowInNanosecondTime() - self.syncRange.nanos

    debug "periodic prune done", storageSize = self.storage.len

    continue

proc start*(self: WakuSync) =
  self.started = true

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
