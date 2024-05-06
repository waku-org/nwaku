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

type WakuSync* = ref object of LPProtocol
  storage: Storage # Negentropy protocol storage 
  peerManager: PeerManager
  maxFrameSize: int # Not sure if this should be protocol defined or not...
  syncInterval: timer.Duration # Time between each syncronisation attempt
  relayJitter: int64 # Time delay until all messages are mostly received network wide
  callback: Option[WakuSyncCallback] # Callback with the result of the syncronisation
  periodicSyncFut: Future[void]

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

proc calculateRange(relayJitter: int64): (int64, int64) =
  var now = getNowInNanosecondTime()

  # Because of message jitter inherent to GossipSub
  now -= relayJitter

  let range = getNanosecondTime(3600) # 1 hour

  let start = now - range
  let `end` = now

  return (start, `end`)

proc request(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let (start, `end`) = calculateRange(self.relayJitter)

  let frameSize = DefaultFrameSize

  let initialized = ?clientInitialize(self.storage, conn, frameSize, start, `end`)

  debug "sync session initialized",
    client = self.peerManager.switch.peerInfo.peerId,
    server = conn.peerId,
    frameSize = frameSize,
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

  let frameSize = DefaultFrameSize

  let initialized = ?serverInitialize(self.storage, conn, frameSize, start, `end`)

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
    relayJitter: int64 = 20, #Default gossipsub jitter in network.
    callback: Option[WakuSyncCallback] = none(WakuSyncCallback),
): T =
  let storage = Storage.new().valueOr:
    debug "storage creation failed"
    return

  let sync = WakuSync(
    storage: storage,
    peerManager: peerManager,
    maxFrameSize: maxFrameSize,
    syncInterval: syncInterval,
    callback: callback,
    relayJitter: relayJitter,
  )

  sync.initProtocolHandler()

  info "WakuSync protocol initialized"

  return sync

proc periodicSync(self: WakuSync) {.async.} =
  while true:
    await sleepAsync(self.syncInterval)

    let (hashes, peer) = (await self.sync()).valueOr:
      debug "periodic sync error", error = error
      continue

    let callback = self.callback.valueOr:
      continue

    await callback(hashes, peer)

proc start*(self: WakuSync) =
  self.started = true
  if self.syncInterval > ZeroDuration:
    # start periodic-sync only if interval is set.
    self.periodicSyncFut = self.periodicSync()

  info "WakuSync protocol started"

proc stopWait*(self: WakuSync) {.async.} =
  await self.periodicSyncFut.cancelAndWait()

  info "WakuSync protocol stopped"
