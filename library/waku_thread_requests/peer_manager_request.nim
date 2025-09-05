import std/[sequtils, strutils]
import chronicles, chronos, results, options, json, ffi
import ../../waku/factory/waku, ../../waku/node/waku_node, ../../waku/node/peer_manager

type PeerInfo = object
  protocols: seq[string]
  addresses: seq[string]

registerReqFFI(GetPeerIdsFromPeerStoreReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    ## returns a comma-separated string of peerIDs
    let peerIDs =
      waku[].node.peerManager.switch.peerStore.peers().mapIt($it.peerId).join(",")
    return ok(peerIDs)

registerReqFFI(ConnectToReq, waku: ptr Waku):
  proc(
      peerMultiAddr: cstring, timeoutMs: cuint
  ): Future[Result[string, string]] {.async.} =
    let peers = ($peerMultiAddr).split(",").mapIt(strip(it))
    await waku.node.connectToNodes(peers, source = "static")
    return ok("")

registerReqFFI(DisconnectPeerByIdReq, waku: ptr Waku):
  proc(peerId: cstring): Future[Result[string, string]] {.async.} =
    let pId = PeerId.init($peerId).valueOr:
      error "DISCONNECT_PEER_BY_ID failed", error = $error
      return err($error)
    await waku.node.peerManager.disconnectNode(pId)
    return ok("")

registerReqFFI(DisconnectAllPeersReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    await waku[].node.peerManager.disconnectAllPeers()
    return ok("")

registerReqFFI(DialPeerReq, waku: ptr Waku):
  proc(
      peerMultiAddr: cstring, protocol: cstring, timeoutMs: cuint
  ): Future[Result[string, string]] {.async.} =
    let remotePeerInfo = parsePeerInfo($peerMultiAddr).valueOr:
      error "DIAL_PEER failed", error = $error
      return err($error)
    let conn = await waku.node.peerManager.dialPeer(remotePeerInfo, $protocol)
    if conn.isNone():
      let msg = "failed dialing peer"
      error "DIAL_PEER failed", error = msg, peerId = $remotePeerInfo.peerId
      return err(msg)
    return ok("")

registerReqFFI(DialPeerByIdReq, waku: ptr Waku):
  proc(
      peerId: cstring, protocol: cstring, timeoutMs: cuint
  ): Future[Result[string, string]] {.async.} =
    let pId = PeerId.init($peerId).valueOr:
      error "DIAL_PEER_BY_ID failed", error = $error
      return err($error)
    let conn = await waku.node.peerManager.dialPeer(pId, $protocol)
    if conn.isNone():
      let msg = "failed dialing peer"
      error "DIAL_PEER_BY_ID failed", error = msg, peerId = $peerId
      return err(msg)

    return ok("")

registerReqFFI(GetConnectedPeersInfoReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    ## returns a JSON string mapping peerIDs to objects with protocols and addresses

    var peersMap = initTable[string, PeerInfo]()
    let peers = waku.node.peerManager.switch.peerStore.peers().filterIt(
        it.connectedness == Connected
      )

    # Build a map of peer IDs to peer info objects
    for peer in peers:
      let peerIdStr = $peer.peerId
      peersMap[peerIdStr] =
        PeerInfo(protocols: peer.protocols, addresses: peer.addrs.mapIt($it))

    # Convert the map to JSON string
    let jsonObj = %*peersMap
    let jsonStr = $jsonObj
    return ok(jsonStr)

registerReqFFI(GetConnectedPeersReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    ## returns a comma-separated string of peerIDs
    let
      (inPeerIds, outPeerIds) = waku[].node.peerManager.connectedPeers()
      connectedPeerids = concat(inPeerIds, outPeerIds)
    return ok(connectedPeerids.mapIt($it).join(","))

registerReqFFI(GetConnectedPeerIdsByProtocolReq, waku: ptr Waku):
  proc(protocol: cstring): Future[Result[string, string]] {.async.} =
    ## returns a comma-separated string of peerIDs that mount the given protocol
    let connectedPeers = waku.node.peerManager.switch.peerStore
      .peers($protocol)
      .filterIt(it.connectedness == Connected)
      .mapIt($it.peerId)
      .join(",")
    return ok(connectedPeers)
