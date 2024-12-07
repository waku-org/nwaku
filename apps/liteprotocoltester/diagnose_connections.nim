when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, net, strformat],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  libp2p/crypto/crypto,
  confutils,
  libp2p/wire

import
  waku/[
    factory/external_config,
    node/peer_manager,
    waku_lightpush/common,
    waku_relay,
    waku_filter_v2,
    waku_peer_exchange/protocol,
    waku_core/multiaddrstr,
    waku_enr/capabilities,
  ]
logScope:
  topics = "diagnose connections"

proc `$`*(cap: Capabilities): string =
  case cap
  of Capabilities.Relay:
    return "Relay"
  of Capabilities.Store:
    return "Store"
  of Capabilities.Filter:
    return "Filter"
  of Capabilities.Lightpush:
    return "Lightpush"
  of Capabilities.Sync:
    return "Sync"

proc allPeers(pm: PeerManager): string =
  var allStr: string = ""
  for idx, peer in pm.wakuPeerStore.peers():
    allStr.add(
      "    " & $idx & ". | " & constructMultiaddrStr(peer) & " | agent: " &
        peer.getAgent() & " | protos: " & $peer.protocols & " | caps: " &
        $peer.enr.map(getCapabilities) & "\n"
    )
  return allStr

proc logSelfPeers*(pm: PeerManager) =
  let selfLighpushPeers = pm.wakuPeerStore.getPeersByProtocol(WakuLightPushCodec)
  let selfRelayPeers = pm.wakuPeerStore.getPeersByProtocol(WakuRelayCodec)
  let selfFilterPeers = pm.wakuPeerStore.getPeersByProtocol(WakuFilterSubscribeCodec)
  let selfPxPeers = pm.wakuPeerStore.getPeersByProtocol(WakuPeerExchangeCodec)

  let printable = catch:
    """*------------------------------------------------------------------------------------------*
|  Self ({constructMultiaddrStr(pm.switch.peerInfo)}) peers:
*------------------------------------------------------------------------------------------*
|  Lightpush peers({selfLighpushPeers.len()}): ${selfLighpushPeers}
*------------------------------------------------------------------------------------------*
|  Filter peers({selfFilterPeers.len()}): ${selfFilterPeers}
*------------------------------------------------------------------------------------------*
|  Relay peers({selfRelayPeers.len()}): ${selfRelayPeers}
*------------------------------------------------------------------------------------------*
|  PX peers({selfPxPeers.len()}): ${selfPxPeers}
*------------------------------------------------------------------------------------------*
| All peers with protocol support:
{allPeers(pm)}
*------------------------------------------------------------------------------------------*""".fmt()

  if printable.isErr():
    echo "Error while printing statistics: " & printable.error().msg
  else:
    echo printable.get()
