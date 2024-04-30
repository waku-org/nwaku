when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, times],
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

const DefaultSyncInterval: timer.Duration = Hour
const DefaultFrameSize = 153600

type
  WakuSyncCallback* = proc(hashes: seq[WakuMessageHash], syncPeer: RemotePeerInfo) {.
    async: (raises: []), closure, gcsafe
  .}

  WakuSync* = ref object of LPProtocol
    storage: Storage
    peerManager: PeerManager
    maxFrameSize: int # Not sure if this should be protocol defined or not...
    syncInterval: timer.Duration
    callback: Option[WakuSyncCallback]
    periodicSyncFut: Future[void]

proc ingessMessage*(self: WakuSync, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if msg.ephemeral:
    return
  #TODO: Do we need to check if this message has already been ingessed? 
  # because what if messages is received via gossip and sync as well?
  # Might 2 entries to be inserted into storage which is inefficient.
  let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic, msg)
  info "inserting message into storage ", hash = msgHash, timestamp = msg.timestamp

  if self.storage.insert(msg.timestamp, msgHash).isErr():
    debug "failed to insert message ", hash = msgHash.toHex()

proc request(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let syncSession = SyncSession(
    sessType: SyncSessionType.CLIENT,
    curState: SyncSessionState.INIT,
    frameSize: DefaultFrameSize,
    rangeStart: 0, #TODO: Pass start of this hour??
    rangeEnd: times.getTime().toUnix(),
  )
  let hashes = (await syncSession.HandleClientSession(conn, self.storage)).valueOr:
    return err(error)
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
    return err("Sync request error: " & error)

  return ok((hashes, peer))

proc sync*(
    self: WakuSync, peer: RemotePeerInfo
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let connOpt = await self.peerManager.dialPeer(peer, WakuSyncCodec)
  let conn: Connection = connOpt.valueOr:
    return err("Cannot establish sync connection")

  let hashes: seq[WakuMessageHash] = (await self.request(conn)).valueOr:
    return err("Sync request error: " & error)

  return ok(hashes)

proc initProtocolHandler(self: WakuSync) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let syncSession = SyncSession(
      sessType: SyncSessionType.SERVER,
      curState: SyncSessionState.INIT,
      frameSize: DefaultFrameSize,
      rangeStart: 0, #TODO: Pass start of this hour??
      rangeEnd: 0,
    )
    debug "Server sync session requested", remotePeer = $conn.peerId

    await syncSession.HandleServerSession(conn, self.storage)

    debug "Server sync session ended"

  self.handler = handle
  self.codec = WakuSyncCodec

proc new*(
    T: type WakuSync,
    peerManager: PeerManager,
    maxFrameSize: int = DefaultFrameSize,
    syncInterval: timer.Duration = DefaultSyncInterval,
    callback: Option[WakuSyncCallback] = none(WakuSyncCallback),
): T =
  let storage = Storage.new().valueOr:
    error "storage creation failed"
    return

  let sync = WakuSync(
    storage: storage,
    peerManager: peerManager,
    maxFrameSize: maxFrameSize,
    syncInterval: syncInterval,
    callback: callback,
  )

  sync.initProtocolHandler()

  info "Created WakuSync protocol"

  return sync

proc periodicSync(self: WakuSync) {.async.} =
  while true:
    await sleepAsync(self.syncInterval)

    let (hashes, peer) = (await self.sync()).valueOr:
      error "periodic sync error", error = error
      continue

    let callback = self.callback.valueOr:
      continue

    await callback(hashes, peer)

proc start*(self: WakuSync) =
  self.started = true
  if self.syncInterval > ZeroDuration:
    # start periodic-sync only if interval is set.
    self.periodicSyncFut = self.periodicSync()

proc stopWait*(self: WakuSync) {.async.} =
  await self.periodicSyncFut.cancelAndWait()

#[ TODO:Fetch from storageManager??
 proc storageSize*(self: WakuSync): int =
  return self.storage.size() ]#
