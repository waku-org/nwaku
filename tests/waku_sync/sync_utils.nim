{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import waku/[node/peer_manager, waku_core, waku_sync], ../testlib/wakucore

proc newTestWakuSync*(
    switch: Switch,
    transfer: Option[TransferCallback] = none(TransferCallback),
    prune: Option[PruneCallback] = none(PruneCallback),
    interval: Duration = DefaultSyncInterval,
): Future[WakuSync] {.async.} =
  let peerManager = PeerManager.new(switch)

  let fakePruneCallback = proc(
      pruneStart: Timestamp, pruneStop: Timestamp, cursor: Option[WakuMessageHash]
  ): Future[
      Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
  ] {.async: (raises: []), closure.} =
    return ok((@[], none(WakuMessageHash)))

  let res = await WakuSync.new(
    peerManager = peerManager,
    relayJitter = 0.seconds,
    syncInterval = interval,
    wakuArchive = nil,
    wakuStoreClient = nil,
    pruneCallback = some(fakePruneCallback),
    transferCallback = none(TransferCallback),
  )

  let proto = res.get()

  proto.start()
  switch.mount(proto)

  return proto
