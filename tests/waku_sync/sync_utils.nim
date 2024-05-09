{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import ../../../waku/[node/peer_manager, waku_core, waku_sync], ../testlib/wakucore

proc newTestWakuSync*(
    switch: Switch,
    transfer: Option[TransferCallback] = none(TransferCallback),
    prune: Option[PruneCallback] = none(PruneCallback),
    interval: Duration = DefaultSyncInterval,
): WakuSync =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuSync.new(
      peerManager = peerManager,
      relayJitter = 0.seconds,
      transferCB = transfer,
      pruneCB = prune,
      syncInterval = interval,
    )
  assert proto != nil

  proto.start()
  switch.mount(proto)

  return proto
