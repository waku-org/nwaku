when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  chronicles,
  json_rpc/rpcserver,
  libp2p/[peerinfo, switch]
import
  ../../../waku_store,
  ../../../waku_filter,
  ../../../waku_relay,
  ../../peer_manager,
  ../../waku_node,
  ./types


logScope:
  topics = "waku node jsonrpc admin_api"



proc constructMultiaddrStr*(wireaddr: MultiAddress, peerId: PeerId): string =
  # Constructs a multiaddress with both wire address and p2p identity
  $wireaddr & "/p2p/" & $peerId

proc constructMultiaddrStr*(peerInfo: PeerInfo): string =
  # Constructs a multiaddress with both location (wire) address and p2p identity
  if peerInfo.listenAddrs.len == 0:
    return ""
  constructMultiaddrStr(peerInfo.listenAddrs[0], peerInfo.peerId)

proc constructMultiaddrStr*(remotePeerInfo: RemotePeerInfo): string =
  # Constructs a multiaddress with both location (wire) address and p2p identity
  if remotePeerInfo.addrs.len == 0:
    return ""
  constructMultiaddrStr(remotePeerInfo.addrs[0], remotePeerInfo.peerId)

proc installAdminApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =

  rpcsrv.rpc("post_waku_v2_admin_v1_peers") do (peers: seq[string]) -> bool:
    ## Connect to a list of peers
    debug "post_waku_v2_admin_v1_peers"

    for i, peer in peers:
      let peerInfo = parsePeerInfo(peer)
      if peerInfo.isErr():
        raise newException(ValueError, "Couldn't parse remote peer info: " & peerInfo.error)

      let connOk = await node.peerManager.connectRelay(peerInfo.value, source="rpc")
      if not connOk:
        raise newException(ValueError, "Failed to connect to peer at index: " & $i & " " & $peer)

    return true

  rpcsrv.rpc("get_waku_v2_admin_v1_peers") do () -> seq[WakuPeer]:
    ## Returns a list of peers registered for this node
    debug "get_waku_v2_admin_v1_peers"

    var peers = newSeq[WakuPeer]()

    if not node.wakuRelay.isNil():
      # Map managed peers to WakuPeers and add to return list
      let relayPeers = node.peerManager.peerStore.peers(WakuRelayCodec)
          .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(it),
                          protocol: WakuRelayCodec,
                          connected: it.connectedness == Connectedness.Connected))
      peers.add(relayPeers)

    if not node.wakuFilterLegacy.isNil():
      # Map WakuFilter peers to WakuPeers and add to return list
      let filterPeers = node.peerManager.peerStore.peers(WakuLegacyFilterCodec)
          .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(it),
                          protocol: WakuLegacyFilterCodec,
                          connected: it.connectedness == Connectedness.Connected))
      peers.add(filterPeers)

    if not node.wakuStore.isNil():
      # Map WakuStore peers to WakuPeers and add to return list
      let storePeers = node.peerManager.peerStore.peers(WakuStoreCodec)
          .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(it),
                        protocol: WakuStoreCodec,
                        connected: it.connectedness == Connectedness.Connected))
      peers.add(storePeers)

    return peers
