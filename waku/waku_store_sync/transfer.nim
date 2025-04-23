{.push raises: [].}

import
  std/sets,
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
  ../waku_enr,
  ../waku_core/codecs,
  ../waku_core/message/digest,
  ../waku_core/message/message,
  ../waku_core/message/default_values,
  ../node/peer_manager/peer_manager,
  ../waku_archive,
  ../waku_archive/common,
  ./common,
  ./codec,
  ./protocols_metrics

logScope:
  topics = "waku transfer"

type SyncTransfer* = ref object of LPProtocol
  wakuArchive: WakuArchive
  peerManager: PeerManager

  # Send IDs to reconciliation protocol for storage
  idsTx: AsyncQueue[SyncID]

  # Receive Hashes from reconciliation protocol for reception
  localWantsRx: AsyncQueue[PeerId]
  localWantsRxFut: Future[void]
  inSessions: HashSet[PeerId]

  # Receive Hashes from reconciliation protocol for transmission
  remoteNeedsRx: AsyncQueue[(PeerId, WakuMessageHash)]
  remoteNeedsRxFut: Future[void]
  outSessions: Table[PeerId, Connection]

proc sendMessage(
    conn: Connection, payload: WakuMessageAndTopic
): Future[Result[void, string]] {.async.} =
  let rawPayload = payload.encode().buffer

  total_bytes_exchanged.inc(rawPayload.len, labelValues = [Transfer, Sending])

  let writeRes = catch:
    await conn.writeLP(rawPayload)

  if writeRes.isErr():
    return
      err("remote " & $conn.peerId & " connection write error: " & writeRes.error.msg)

  total_transfer_messages_exchanged.inc(labelValues = [Sending])

  return ok()

proc openConnection(
    self: SyncTransfer, peerId: PeerId
): Future[Result[Connection, string]] {.async.} =
  let connOpt = await self.peerManager.dialPeer(peerId, WakuTransferCodec)

  let conn: Connection = connOpt.valueOr:
    return err("fail to dial remote " & $peerId)

  debug "transfer session initialized",
    local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

  return ok(conn)

proc wantsReceiverLoop(self: SyncTransfer) {.async.} =
  ## Waits for message hashes,
  ## store the peers and hashes locally as
  ## "supposed to be received"

  while true: # infinite loop
    let peerId = await self.localWantsRx.popFirst()

    if self.inSessions.containsOrIncl(peerId):
      self.inSessions.excl(peerId)

  return

proc needsReceiverLoop(self: SyncTransfer) {.async.} =
  ## Waits for message hashes,
  ## open connection to the other peers,
  ## get the messages from DB and then send them.

  while true: # infinite loop
    let (peerId, fingerprint) = await self.remoteNeedsRx.popFirst()

    if not self.outSessions.hasKey(peerId):
      let connection = (await self.openConnection(peerId)).valueOr:
        error "failed to establish transfer connection", error = error
        continue

      self.outSessions[peerid] = connection

    let connection = self.outSessions[peerId]

    var query = ArchiveQuery()
    query.includeData = true
    query.hashes = @[fingerprint]

    let response = (await self.wakuArchive.findMessages(query)).valueOr:
      error "failed to query archive", error = error
      continue

    if response.messages.len < 1:
      error "failed to fetch message from db"
      continue

    let msg =
      WakuMessageAndTopic(pubsub: response.topics[0], message: response.messages[0])

    (await sendMessage(connection, msg)).isOkOr:
      self.outSessions.del(peerId)
      await connection.close()
      error "failed to send message", error = error
      continue

  return

proc initProtocolHandler(self: SyncTransfer) =
  let handler = proc(conn: Connection, proto: string) {.async, closure.} =
    while true:
      if not self.inSessions.contains(conn.peerId):
        error "unwanted peer, disconnecting", remote = conn.peerId
        break

      let readRes = catch:
        await conn.readLp(int64(DefaultMaxWakuMessageSize))

      let buffer: seq[byte] = readRes.valueOr:
        # connection closed normally
        break

      total_bytes_exchanged.inc(buffer.len, labelValues = [Transfer, Receiving])

      let payload = WakuMessageAndTopic.decode(buffer).valueOr:
        error "decoding error", error = $error
        continue

      total_transfer_messages_exchanged.inc(labelValues = [Receiving])

      let msg = payload.message
      let pubsub = payload.pubsub

      let hash = computeMessageHash(pubsub, msg)

      #TODO verify msg RLN proof...

      (await self.wakuArchive.syncMessageIngress(hash, pubsub, msg)).isOkOr:
        error "failed to archive message", error = $error
        continue

      let id = SyncID(time: msg.timestamp, hash: hash)
      await self.idsTx.addLast(id)

      continue

    await conn.close()

    debug "transfer session ended",
      local = self.peerManager.switch.peerInfo.peerId, remote = conn.peerId

    return

  self.handler = handler
  self.codec = WakuTransferCodec

proc new*(
    T: type SyncTransfer,
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    idsTx: AsyncQueue[SyncID],
    localWantsRx: AsyncQueue[PeerId],
    remoteNeedsRx: AsyncQueue[(PeerId, WakuMessageHash)],
): T =
  var transfer = SyncTransfer(
    peerManager: peerManager,
    wakuArchive: wakuArchive,
    idsTx: idsTx,
    localWantsRx: localWantsRx,
    remoteNeedsRx: remoteNeedsRx,
  )

  transfer.initProtocolHandler()

  info "Store Transfer protocol initialized"

  return transfer

proc start*(self: SyncTransfer) =
  if self.started:
    return

  self.started = true

  self.localWantsRxFut = self.wantsReceiverLoop()
  self.remoteNeedsRxFut = self.needsReceiverLoop()

  info "Store Sync Transfer protocol started"

proc stop*(self: SyncTransfer) =
  self.started = false

  self.localWantsRxFut.cancelSoon()
  self.remoteNeedsRxFut.cancelSoon()

  info "Store Sync Transfer protocol stopped"
