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
  trace "Starting logSelfPeersLoop diagnosys loop"
  while true:
    let selfLighpushPeers = pm.peerStore.getPeersByProtocol(WakuLightPushCodec)
    let selfRelayPeers = pm.peerStore.getPeersByProtocol(WakuRelayCodec)
    let selfFilterPeers = pm.peerStore.getPeersByProtocol(WakuFilterSubscribeCodec)

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

proc logServiceRelayPeers(
    pm: PeerManager, codec: string, interval: Duration
) {.async.} =
  trace "Starting service node connectivity diagnosys loop"
  while true:
    echo "*------------------------------------------------------------------------------------------*"
    echo "|  Service peer connectivity:"
    let selfLighpushPeers = pm.selectPeer(codec)
    if selfLighpushPeers.isSome():
      let ma = selfLighpushPeers.get().addrs[0]
      var serviceIp = initTAddress(ma).valueOr:
        echo "Error while parsing multiaddress: " & $error
        continue

      serviceIp.port = Port(8645)
      let restClient = newRestHttpClient(initTAddress($serviceIp))

      let getPeersRes = await restClient.getPeers()

      if getPeersRes.status == 200:
        let nrOfPeers = getPeersRes.data.len()
        echo "Service node (@" & $ma & ") peers: " & $getPeersRes.data
      else:
        echo "Error while fetching service node (@" & $ma & ") peers: " &
          $getPeersRes.data
    else:
      echo "No service node peers found"

    echo "*------------------------------------------------------------------------------------------*"

    await sleepAsync(interval)

proc startPeriodicPeerDiagnostic*(pm: PeerManager, codec: string) {.async.} =
  asyncSpawn logSelfPeersLoop(pm, chronos.seconds(20))
  # asyncSpawn logServiceRelayPeers(pm, codec, chronos.seconds(20))
