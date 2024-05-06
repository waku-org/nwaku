when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options],
  stew/results,
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
  ../waku_enr,
  ../node/peer_manager/peer_manager,
  ./raw_bindings,
  ./common,
  ./session,
  ./storage_manager

logScope:
  topics = "waku sync"

type WakuSync* = ref object of LPProtocol
  storage: Storage # Negentropy protocol storage 
  peerManager: PeerManager
  maxFrameSize: int
  syncInterval: timer.Duration # Time between each syncronisation attempt
  relayJitter: Duration # Time delay until all messages are mostly received network wide
  syncCallBack: Option[SyncCallBack] # Callback with the result of the syncronisation
  pruneCallBack: Option[PruneCallBack] # Callback with the result of the archive query
  pruneStart: Timestamp # Last pruning start timestamp 
  pruneInterval: Duration # Time between each pruning attempt
  periodicSyncFut: Future[void]
  periodicPruneFut: Future[void]

proc ingessMessage*(self: WakuSync, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if msg.ephemeral:
    return
  #TODO: Do we need to check if this message has already been ingessed? 
  # because what if messages is received via gossip and sync as well?
  # Might 2 entries to be inserted into storage which is inefficient.
  let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic, msg)

  trace "inserting message into storage ",
    hash = msgHash.toHex(), timestamp = msg.timestamp

  if self.storage.insert(msg.timestamp, msgHash).isErr():
    debug "failed to insert message ", hash = msgHash.toHex()

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
    self: WakuSync
): Future[Result[(seq[WakuMessageHash], RemotePeerInfo), string]] {.async, gcsafe.} =
  let peer: RemotePeerInfo = self.peerManager.selectPeer(WakuSyncCodec).valueOr:
    return err("No suitable peer found for sync")
  let connOpt = await self.peerManager.dialPeer(peer, WakuSyncCodec)
  let conn: Connection = connOpt.valueOr:
    return err("Cannot establish sync connection")

  let hashes: seq[WakuMessageHash] = (await self.request(conn)).valueOr:
    debug "sync session ended",
      server = self.peerManager.switch.peerInfo.peerId,
      client = conn.peerId,
      error = $error
    return err("Sync request error: " & error)

  return ok((hashes, peer))

proc sync*(
    self: WakuSync, peer: RemotePeerInfo
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let connOpt = await self.peerManager.dialPeer(peer, WakuSyncCodec)
  let conn: Connection = connOpt.valueOr:
    return err("Cannot establish sync connection")

  let hashes: seq[WakuMessageHash] = (await self.request(conn)).valueOr:
    debug "sync session ended",
      server = self.peerManager.switch.peerInfo.peerId,
      client = conn.peerId,
      error = $error

    return err("Sync request error: " & error)

  return ok(hashes)

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
        server = self.peerManager.switch.peerInfo.peerId,
        client = conn.peerId,
        error = $error

      #TODO send error code and desc to client
      return

    #TODO handle the hashes that the server need from the client

    debug "sync session ended gracefully",
      server = self.peerManager.switch.peerInfo.peerId, client = conn.peerId

  self.handler = handle
  self.codec = WakuSyncCodec

proc new*(
    T: type WakuSync,
    peerManager: PeerManager,
    maxFrameSize: int = DefaultFrameSize,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: Duration = DefaultGossipSubJitter,
      #Default gossipsub jitter in network.
    syncCB: Option[SyncCallback] = none(SyncCallback),
    pruneInterval: Duration = DefaultPruneInterval,
    pruneCB: Option[PruneCallBack] = none(PruneCallback),
): T =
  let storage = Storage.new().valueOr:
    debug "storage creation failed"
    return

  let sync = WakuSync(
    storage: storage,
    peerManager: peerManager,
    maxFrameSize: maxFrameSize,
    syncInterval: syncInterval,
    relayJitter: relayJitter,
    syncCallBack: syncCB,
    pruneCallBack: pruneCB,
    pruneStart: getNowInNanosecondTime(),
    pruneInterval: pruneInterval,
  )

  sync.initProtocolHandler()

  info "WakuSync protocol initialized"

  return sync

proc periodicSync(self: WakuSync) {.async.} =
  while true:
    await sleepAsync(self.syncInterval)

    let (hashes, peer) = (await self.sync()).valueOr:
      debug "periodic sync failed", error = error
      continue

    let callback = self.syncCallBack.valueOr:
      continue

    await callback(hashes, peer)

proc periodicPrune(self: WakuSync) {.async.} =
  let callback = self.pruneCallBack.valueOr:
    return

  while true:
    await sleepAsync(self.pruneInterval)

    let pruneStop = getNowInNanosecondTime()

    var (elements, cursor) =
      (newSeq[(WakuMessageHash, Timestamp)](0), none(WakuMessageHash))

    while true:
      (elements, cursor) = (await callback(self.pruneStart, pruneStop, cursor)).valueOr:
        debug "storage pruning failed", error = $error
        break

      if elements.len == 0:
        break

      for (hash, timestamp) in elements:
        self.storage.erase(timestamp, hash).isOkOr:
          trace "element pruning failed", time = timestamp, hash = hash, error = error
          continue

      if cursor.isNone():
        break

    self.pruneStart = pruneStop

proc start*(self: WakuSync) =
  self.started = true

  if self.syncCallBack.isSome() and self.syncInterval > ZeroDuration:
    self.periodicSyncFut = self.periodicSync()

  if self.pruneCallBack.isSome() and self.pruneInterval > ZeroDuration:
    self.periodicPruneFut = self.periodicPrune()

  info "WakuSync protocol started"

proc stopWait*(self: WakuSync) {.async.} =
  await self.periodicSyncFut.cancelAndWait()

  info "WakuSync protocol stopped"
