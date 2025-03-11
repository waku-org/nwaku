{.used.}

import std/options, chronicles, chronos, libp2p/crypto/crypto

import
  waku/node/peer_manager,
  waku/waku_core,
  waku/waku_core/topics/sharding,
  waku/waku_lightpush,
  waku/waku_lightpush/[client, common],
  waku/common/rate_limit/setting,
  ../testlib/[common, wakucore],
  waku/incentivization/reputation_manager

proc newTestWakuLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    wakuSharding = Sharding(clusterId: 1, shardCountGenZero: 8)
    proto = WakuLightPush.new(peerManager, rng, handler, wakuSharding, rateLimitSetting)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLightpushClient*(
  switch: Switch,
  reputationEnabled: bool = false
  ): WakuLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLightPushClient.new(peerManager, rng, reputationEnabled)
