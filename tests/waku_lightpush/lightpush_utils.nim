{.used.}

import std/options, chronicles, chronos, libp2p/crypto/crypto

import
  ../../waku/node/peer_manager,
  ../../waku/waku_core,
  ../../waku/waku_lightpush,
  ../../waku/waku_lightpush/[client, common],
  ../testlib/[common, wakucore]

proc newTestWakuLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuLightPush.new(peerManager, rng, handler, rateLimitSetting)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLightpushClient*(switch: Switch): WakuLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLightPushClient.new(peerManager, rng)
