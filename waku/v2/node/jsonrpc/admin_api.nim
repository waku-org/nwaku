{.push raises: [Exception, Defect].}

import
  std/[options, sequtils, sets],
  json_rpc/rpcserver,
  libp2p/[peerinfo, switch],
  ../../protocol/waku_store/[waku_store_types, waku_store],
  ../../protocol/waku_swap/[waku_swap_types, waku_swap],
  ../../protocol/waku_filter/[waku_filter_types, waku_filter],
  ../../protocol/waku_relay,
  ../wakunode2,
  ../peer_manager,
  ./jsonrpc_types

export jsonrpc_types

const futTimeout* = 30.seconds # Max time to wait for futures

proc constructMultiaddrStr*(wireaddr: MultiAddress, peerId: PeerId): string =
  # Constructs a multiaddress with both wire address and p2p identity
  $wireaddr & "/p2p/" & $peerId

proc constructMultiaddrStr*(peerInfo: PeerInfo): string =
  # Constructs a multiaddress with both location (wire) address and p2p identity
  constructMultiaddrStr(peerInfo.addrs[0], peerInfo.peerId)

proc installAdminApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =

  ## Admin API version 1 definitions
  
  rpcsrv.rpc("post_waku_v2_admin_v1_peers") do(peers: seq[string]) -> bool:
    ## Connect to a list of peers
    debug "post_waku_v2_admin_v1_peers"

    if (await node.connectToNodes(peers).withTimeout(futTimeout)):
      # Successfully connected to peers
      return true
    else:
      # Failed to connect to peers
      raise newException(ValueError, "Failed to connect to peers: " & $peers)

  rpcsrv.rpc("get_waku_v2_admin_v1_peers") do() -> seq[WakuPeer]:
    ## Returns history for a list of content topics with optional paging
    debug "get_waku_v2_admin_v1_peers"

    # Create a single list of peers from mounted protocols.
    # @TODO since the switch does not expose its connections, retrieving the connected peers requires a peer store/peer management

    var wPeers: seq[WakuPeer] = @[]

    ## Managed peers

    if not node.wakuRelay.isNil:
      # Map managed peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peers(WakuRelayCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(toSeq(it.addrs.items)[0], it.peerId),
                                                    protocol: WakuRelayCodec,
                                                    connected: node.peerManager.connectedness(it.peerId) == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence
      
    if not node.wakuFilter.isNil:
      # Map WakuFilter peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peers(WakuFilterCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(toSeq(it.addrs.items)[0], it.peerId),
                                                    protocol: WakuFilterCodec,
                                                    connected: node.peerManager.connectedness(it.peerId) == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence
    
    if not node.wakuSwap.isNil:
      # Map WakuSwap peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peers(WakuSwapCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(toSeq(it.addrs.items)[0], it.peerId),
                                                    protocol: WakuSwapCodec,
                                                    connected: node.peerManager.connectedness(it.peerId) == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence

    if not node.wakuStore.isNil:
      # Map WakuStore peers to WakuPeers and add to return list
      wPeers.insert(node.peerManager.peers(WakuStoreCodec)
                                    .mapIt(WakuPeer(multiaddr: constructMultiaddrStr(toSeq(it.addrs.items)[0], it.peerId),
                                                    protocol: WakuStoreCodec,
                                                    connected: node.peerManager.connectedness(it.peerId) == Connectedness.Connected)),
                    wPeers.len) # Append to the end of the sequence

    # @TODO filter output on protocol/connected-status
    return wPeers
