{.used.}

import std/[options, random], chronos, chronicles

import waku/[node/peer_manager, waku_core, waku_store_sync], ../testlib/wakucore

randomize()

proc randomHash*(rng: var Rand): WakuMessageHash =
  var hash = EmptyWakuMessageHash

  for i in 0 ..< hash.len:
    hash[i] = rng.rand(uint8)

  return hash

proc newTestWakuRecon*(
    switch: Switch,
    idsRx: AsyncQueue[ID],
    wantsTx: AsyncQueue[(PeerId, Fingerprint)],
    needsTx: AsyncQueue[(PeerId, Fingerprint)],
): Future[SyncReconciliation] {.async.} =
  let peerManager = PeerManager.new(switch)

  let res = await SyncReconciliation.new(
    peerManager = peerManager,
    wakuArchive = nil,
    relayJitter = 0.seconds,
    idsRx = idsRx,
    wantsTx = wantsTx,
    needsTx = needsTx,
  )

  let proto = res.get()

  proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuTransfer*(
    switch: Switch,
    idsTx: AsyncQueue[ID],
    wantsRx: AsyncQueue[(PeerId, Fingerprint)],
    needsRx: AsyncQueue[(PeerId, Fingerprint)],
): SyncTransfer =
  let peerManager = PeerManager.new(switch)

  let proto = SyncTransfer.new(
    peerManager = peerManager,
    wakuArchive = nil,
    idsTx = idsTx,
    wantsRx = wantsRx,
    needsRx = needsRx,
  )

  proto.start()
  switch.mount(proto)

  return proto
