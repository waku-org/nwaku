{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import
  ../../../waku/
    [node/peer_manager, waku_core, waku_store_legacy, waku_store_legacy/client],
  ../testlib/[common, wakucore]

proc newTestWakuStore*(
    switch: Switch, handler: HistoryQueryHandler
): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuStore.new(peerManager, rng, handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStoreClient*(switch: Switch): WakuStoreClient =
  let peerManager = PeerManager.new(switch)
  WakuStoreClient.new(peerManager, rng)

proc computeHistoryCursor*(
    pubsubTopic: PubsubTopic, message: WakuMessage
): HistoryCursor =
  HistoryCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: computeDigest(message),
  )
