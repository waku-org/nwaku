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
  WakuSyncCallback* = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.}

  WakuSync* = ref object of LPProtocol
    storage: Storage
    negentropy: Negentropy
    peerManager: PeerManager
    maxFrameSize: int # Not sure if this should be protocol defined or not...
    syncInterval: Duration
    callback: Option[WakuSyncCallback]

proc ingessMessage*(self: WakuSync, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if msg.ephemeral:
    return

  let msgHash = computeMessageHash(pubsubTopic, msg)

  self.storage.insert(msg.timestamp, msgHash)

proc serverReconciliation(self: WakuSync, message: seq[byte]): Result[seq[byte], string] =
  let payload = self.negentropy.serverReconcile(message)

  ok(payload)

proc clientReconciliation(
  self: WakuSync, message: seq[byte],
  haveHashes: var seq[WakuMessageHash],
  needHashes: var seq[WakuMessageHash],
  ): Result[Option[seq[byte]], string] =
  let payload = self.negentropy.clientReconcile(message, haveHashes, needHashes)

  ok(some(payload))

proc intitialization(self: WakuSync): Future[Result[seq[byte], string]] {.async.} =
  let payload = self.negentropy.initiate()

  ok(payload)

proc request(self: WakuSync, conn: Connection): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let request = (await self.intitialization()).valueOr:
    return err(error)

  let writeRes = catch: await conn.writeLP(request)
  if writeRes.isErr():
    return err(writeRes.error.msg)

  var
    haveHashes: seq[WakuMessageHash] # What to do with haves ???
    needHashes: seq[WakuMessageHash]

  while true:
    let readRes = catch: await conn.readLp(self.maxFrameSize)
    let buffer = readRes.valueOr:
      return err(error.msg)
  
    let responseOpt = self.clientReconciliation(buffer, haveHashes, needHashes).valueOr:
      return err(error)

    let response =
      if responseOpt.isNone():
        await conn.close()
        break
      else:
        responseOpt.get()

    let writeRes = catch: await conn.writeLP(response)
    if writeRes.isErr():
      return err(writeRes.error.msg)

  return ok(needHashes)

proc sync*(self: WakuSync): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let peer = self.peerManager.selectPeer(WakuSyncCodec).valueOr:
    return err("No suitable peer found for sync")

  let conn = (await self.peerManager.dialPeer(peer, WakuSyncCodec)).valueOr:
    return err("Cannot establish sync connection")

  let hashes = (await self.request(conn)).valueOr:
    return err("Sync request error: " & error)

  ok(hashes)

proc sync*(self: WakuSync, peer: RemotePeerInfo): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let conn = (await self.peerManager.dialPeer(peer, WakuSyncCodec)).valueOr:
    return err("Cannot establish sync connection")

  let hashes = (await self.request(conn)).valueOr:
    return err("Sync request error: " & error)

  ok(hashes)

proc initProtocolHandler(self: WakuSync) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    while not conn.isClosed: # Not sure if this works as I think it does...
      let requestRes = catch: await conn.readLp(self.maxFrameSize)
      let buffer = requestRes.valueOr:
        error "Connection reading error", error=error.msg
        return
    
      let response = self.serverReconciliation(buffer).valueOr:
        error "Reconciliation error", error=error
        return

      let writeRes = catch: await conn.writeLP(response)
      if writeRes.isErr():
        error "Connection write error", error=writeRes.error.msg
        return

  self.handler = handle
  self.codec = WakuSyncCodec

proc new*(T: type WakuSync,
  peerManager: PeerManager,
  maxFrameSize: int = DefaultFrameSize,
  syncInterval: Duration = DefaultSyncInterval,
  callback: Option[WakuSyncCallback] = none(WakuSyncCallback)
): T =
  let storage = Storage.new()

  let negentropy = Negentropy.new(storage, maxFrameSize)

  let sync = WakuSync(
    storage: storage,
    negentropy: negentropy,
    peerManager: peerManager,
    maxFrameSize: maxFrameSize,
    syncInterval: syncInterval,
    callback: callback
  )

  sync.initProtocolHandler()

  info "Created WakuSync protocol"

  return sync

proc periodicSync(self: WakuSync) {.async.} =
  while self.started and self.callback.isSome():
    await sleepAsync(self.syncInterval)

    let hashes = (await self.sync()).valueOr:
      continue

    let callback = self.callback.get()

    await callback(hashes)

proc start*(self: WakuSync) =
  self.started = true

  asyncSpawn self.periodicSync()

proc stop*(self: WakuSync) =
  self.started = false