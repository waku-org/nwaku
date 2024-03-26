when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
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
  ./raw_bindings

logScope:
  topics = "waku sync"

const WakuSyncCodec* = "/vac/waku/sync/1.0.0"
const DefaultFrameSize = 153600 # using a random number for now
const DefaultSyncInterval = 60.minutes

type
  WakuSyncCallback* = proc(hashes: seq[WakuMessageHash], syncPeer: RemotePeerInfo) {.
    async: (raises: []), closure, gcsafe
  .}

  WakuSync* = ref object of LPProtocol
    storage: Storage
    peerManager: PeerManager
    maxFrameSize: int # Not sure if this should be protocol defined or not...
    syncInterval: Duration
    callback: Option[WakuSyncCallback]
    periodicSyncFut: Future[void]

proc ingessMessage*(self: WakuSync, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if msg.ephemeral:
    return

  let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic, msg)
  trace "inserting message into storage ", hash = msgHash

  if self.storage.insert(msg.timestamp, msgHash).isErr():
    debug "failed to insert message ", hash = msgHash.toHex()

proc request(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let negentropy = Negentropy.new(self.storage, self.maxFrameSize).valueOr:
    return err(error)

  defer:
    negentropy.delete()

  let payload = negentropy.initiate().valueOr:
    return err(error)

  debug "Client sync session initialized", remotePeer = conn.peerId

  let writeRes = catch:
    await conn.writeLP(seq[byte](payload))

  trace "request sent to server", payload = toHex(seq[byte](payload))

  if writeRes.isErr():
    return err(writeRes.error.msg)

  var
    haveHashes: seq[WakuMessageHash] # What to do with haves ???
    needHashes: seq[WakuMessageHash]

  while true:
    let readRes = catch:
      await conn.readLp(self.maxFrameSize)

    let buffer: seq[byte] = readRes.valueOr:
      return err(error.msg)

    trace "Received Sync request from peer", payload = toHex(buffer)

    let request = NegentropyPayload(buffer)

    let responseOpt = negentropy.clientReconcile(request, haveHashes, needHashes).valueOr:
      return err(error)

    let response = responseOpt.valueOr:
      debug "Closing connection, client sync session is done"
      await conn.close()
      break

    trace "Sending Sync response to peer", payload = toHex(seq[byte](response))

    let writeRes = catch:
      await conn.writeLP(seq[byte](response))

    if writeRes.isErr():
      return err(writeRes.error.msg)

  return ok(needHashes)

proc sync*(
    self: WakuSync
): Future[Result[(seq[WakuMessageHash], RemotePeerInfo), string]] {.async, gcsafe.} =
  let peer: RemotePeerInfo = self.peerManager.selectPeer(WakuSyncCodec).valueOr:
    return err("No suitable peer found for sync")

  let conn: Connection = (await self.peerManager.dialPeer(peer, WakuSyncCodec)).valueOr:
    return err("Cannot establish sync connection")

  let hashes: seq[WakuMessageHash] = (await self.request(conn)).valueOr:
    return err("Sync request error: " & error)

  return ok((hashes, peer))

proc sync*(
    self: WakuSync, peer: RemotePeerInfo
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let conn: Connection = (await self.peerManager.dialPeer(peer, WakuSyncCodec)).valueOr:
    return err("Cannot establish sync connection")

  let hashes: seq[WakuMessageHash] = (await self.request(conn)).valueOr:
    return err("Sync request error: " & error)

  return ok(hashes)

proc initProtocolHandler(self: WakuSync) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    debug "Server sync session requested", remotePeer = $conn.peerId

    let negentropy = Negentropy.new(self.storage, self.maxFrameSize).valueOr:
      error "Negentropy initialization error", error = error
      return

    defer:
      negentropy.delete()

    while not conn.isClosed:
      let requestRes = catch:
        await conn.readLp(self.maxFrameSize)

      let buffer = requestRes.valueOr:
        if error.name != $LPStreamRemoteClosedError or error.name != $LPStreamClosedError:
          debug "Connection reading error", error = error.msg

        break

      #TODO: Once we receive needHashes or endOfSync, we should close this stream.
      let request = NegentropyPayload(buffer)

      let response = negentropy.serverReconcile(request).valueOr:
        error "Reconciliation error", error = error
        break

      let writeRes = catch:
        await conn.writeLP(seq[byte](response))
      if writeRes.isErr():
        error "Connection write error", error = writeRes.error.msg
        break

    debug "Server sync session ended"

  self.handler = handle
  self.codec = WakuSyncCodec

proc new*(
    T: type WakuSync,
    peerManager: PeerManager,
    maxFrameSize: int = DefaultFrameSize,
    syncInterval: Duration = DefaultSyncInterval,
    callback: Option[WakuSyncCallback] = none(WakuSyncCallback),
): T =
  let storage = Storage.new().valueOr:
    error "storage creation failed"
    return nil

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
  if self.syncInterval > 0.seconds: # start periodic-sync only if interval is set.
    self.periodicSyncFut = self.periodicSync()

proc stopWait*(self: WakuSync) {.async.} =
  await self.periodicSyncFut.cancelAndWait()

proc storageSize*(self: WakuSync): int =
  return self.storage.size()
