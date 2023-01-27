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
  ../../protocol/waku_store,
  ../../protocol/waku_filter,
  ../../protocol/waku_relay,
  ../../protocol/waku_swap/waku_swap,
  ../peer_manager/peer_manager,
  ../waku_node,
  ./jsonrpc_types

export jsonrpc_types

logScope:
  topics = "waku node jsonrpc admin_api"

const futTimeout* = 30.seconds # Max time to wait for futures

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

proc constructMultiaddrStr*(storedInfo: StoredInfo): string =
  # Constructs a multiaddress with both location (wire) address and p2p identity
  if storedInfo.addrs.len == 0:
    return ""
  constructMultiaddrStr(storedInfo.addrs[0], storedInfo.peerId)

proc installAdminApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =

  ## Admin API version 1 definitions

  rpcsrv.rpc("post_waku_v2_admin_v1_peers") do(peers: seq[string]) -> bool:
    ## Connect to a list of peers
    debug "post_waku_v2_admin_v1_peers"

    for i, peer in peers:
      let conn = await node.peerManager.dialPeer(parseRemotePeerInfo(peer), WakuRelayCodec, source="rpc")
      if conn.isNone():
        raise newException(ValueError, "Failed to connect to peer at index: " & $i & " " & $peer)
    return true

  rpcsrv.rpc("get_waku_v2_admin_v1_peers") do() -> seq[WakuPeer]:
    ## Returns a list of peers registered for this node
    debug "get_waku_v2_admin_v1_peers"

    # Create a single list of peers from mounted protocols.
    # @TODO since the switch does not expose its connections, retrieving the connected peers requires a peer store/peer management

    var wPeers: seq[WakuPeer] = @[]

    ## Managed peers

    if not node.wakuRelay.isNil:
      # Map managed peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peerStore
                                    .peers(WakuRelayCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(it),
                                                    protocol: WakuRelayCodec,
                                                    connected: it.connectedness == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence

    if not node.wakuFilter.isNil:
      # Map WakuFilter peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peerStore
                                    .peers(WakuFilterCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(it),
                                                    protocol: WakuFilterCodec,
                                                    connected: it.connectedness == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence

    if not node.wakuSwap.isNil:
      # Map WakuSwap peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peerStore
                                    .peers(WakuSwapCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(it),
                                                    protocol: WakuSwapCodec,
                                                    connected: it.connectedness == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence

    if not node.wakuStore.isNil:
      # Map WakuStore peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peerStore
                                    .peers(WakuStoreCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(it),
                                                    protocol: WakuStoreCodec,
                                                    connected: it.connectedness == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence

    # @TODO filter output on protocol/connected-status
    return wPeers
