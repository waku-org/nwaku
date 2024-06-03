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

  transferCallBack: TransferCallback

  maxFrameSize: int

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

proc eraseMessage*(
    self: WakuSync, timestamp: Timestamp, msgHash: WakuMessageHash
): Result[void, string] =
  self.storage.erase(timestamp, msgHash).isOkOr:
    return err($error)

  return ok()

proc request*(
    self: WakuSync,
    conn: Connection,
    maxFrameSize: int,
    rangeStart: int64,
    rangeEnd: int64,
): Future[Result[seq[WakuMessageHash], string]] {.async, gcsafe.} =
  let initialized =
    ?clientInitialize(self.storage, conn, maxFrameSize, rangeStart, rangeEnd)

  debug "sync session initialized",
    server = conn.peerId,
    frameSize = maxFrameSize,
    timeStart = rangeStart,
    timeEnd = rangeEnd

  var hashes: seq[WakuMessageHash]
  var reconciled = initialized

  while true:
    let sent = ?await reconciled.send()

    trace "sync payload sent", server = conn.peerId, payload = reconciled.payload

    let received = ?await sent.listenBack()

    trace "sync payload received", server = conn.peerId, payload = received.payload

    reconciled = (?received.clientReconcile(hashes)).valueOr:
      let completed = error # Result[Reconciled, Completed]

      ?await completed.clientTerminate()

      debug "sync session ended gracefully", server = conn.peerId

      return ok(hashes)

proc handleLoop(
    self: WakuSync, conn: Connection
): Future[Result[seq[WakuMessageHash], string]] {.async.} =
  let initialized = ?serverInitialize(self.storage, conn, self.maxFrameSize)

  var sent = initialized

  while true:
    let received = ?await sent.listenBack()

    trace "sync payload received", client = conn.peerId, payload = received.payload

    let reconciled = (?received.serverReconcile()).valueOr:
      let completed = error # Result[Reconciled, Completed]

      let hashes = await completed.serverTerminate()

      return ok(hashes)

    sent = ?await reconciled.send()

    trace "sync payload sent", client = conn.peerId, payload = reconciled.payload

proc initProtocolHandler(self: WakuSync) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    debug "sync session requested", client = conn.peerId

    let hashes = (await self.handleLoop(conn)).valueOr:
      debug "sync session ended", client = conn.peerId, error

      #TODO send error code and desc to client
      return

    if hashes.len > 0:
      (await self.transferCallBack(hashes, conn.peerId)).isOkOr:
        error "transfer callback failed", error = $error

    debug "sync session ended gracefully", client = conn.peerId

  self.handler = handle
  self.codec = WakuSyncCodec

proc new*(
    T: type WakuSync, transferCallBack: TransferCallback, maxFrameSize: int
): Result[T, string] =
  let storage = NegentropyStorage.new().valueOr:
    return err("negentropy storage creation failed")

  let sync = WakuSync(storage, transferCallBack, maxFrameSize)

  sync.initProtocolHandler()

  info "WakuSync protocol initialized"

  return ok(sync)
