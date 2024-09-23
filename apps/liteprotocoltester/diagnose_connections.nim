when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, strutils, os, sequtils, net, strformat],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto,
  confutils,
  libp2p/wire

import
  ../../waku/common/logging,
  ../../waku/factory/waku,
  ../../waku/factory/external_config,
  ../../waku/node/health_monitor,
  ../../waku/node/waku_metrics,
  ../../waku/waku_api/rest/builder as rest_server_builder,
  ../../waku/node/peer_manager,
  ../../waku/waku_lightpush/common,
  ../../waku/waku_relay,
  ../../waku/waku_filter_v2,
  ../../waku/waku_api/rest/client,
  ../../waku/waku_api/rest/admin/client,
  ./tester_config,
  ./lightpush_publisher,
  ./filter_subscriber

logScope:
  topics = "diagnose connections"

proc logSelfPeersLoop(pm: PeerManager, interval: Duration) {.async.} =
  trace "Starting logSelfPeersLoop diagnosis loop"
  while true:
    let selfLighpushPeers = pm.wakuPeerStore.getPeersByProtocol(WakuLightPushCodec)
    let selfRelayPeers = pm.wakuPeerStore.getPeersByProtocol(WakuRelayCodec)
    let selfFilterPeers = pm.wakuPeerStore.getPeersByProtocol(WakuFilterSubscribeCodec)

    let printable = catch:
      """*------------------------------------------------------------------------------------------*
|  Self ({pm.switch.peerInfo}) peers:
*------------------------------------------------------------------------------------------*
|  Lightpush peers({selfLighpushPeers.len()}): ${selfLighpushPeers}
*------------------------------------------------------------------------------------------*
|  Filter peers({selfFilterPeers.len()}): ${selfFilterPeers}
*------------------------------------------------------------------------------------------*
|  Relay peers({selfRelayPeers.len()}): ${selfRelayPeers}
*------------------------------------------------------------------------------------------*""".fmt()

    if printable.isErr():
      echo "Error while printing statistics: " & printable.error().msg
    else:
      echo printable.get()

    await sleepAsync(interval)

proc startPeriodicPeerDiagnostic*(pm: PeerManager, codec: string) {.async.} =
  asyncSpawn logSelfPeersLoop(pm, chronos.seconds(60))
