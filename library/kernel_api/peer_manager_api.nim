import std/[strutils, tables, json]
import chronicles, chronos, results, ffi
import logos_delivery, library/declare_lib

type PeerInfo = object
  protocols: seq[string]
  addresses: seq[string]

proc waku_get_peerids_from_peerstore(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peerIds = (await self.kernel.peerIdsFromPeerstore()).valueOr:
    return err(error)
  return ok(peerIds.join(","))

proc waku_connect(
    self: LogosDelivery, peerMultiAddr: string, timeoutMs: uint32
): Future[Result[string, string]] {.ffi.} =
  let peers = peerMultiAddr.split(",")
  (await self.kernel.connect(peers, timeoutMs)).isOkOr:
    return err(error)
  return ok("")

proc waku_disconnect_peer_by_id(
    self: LogosDelivery, peerId: string
): Future[Result[string, string]] {.ffi.} =
  (await self.kernel.disconnectPeerById(peerId)).isOkOr:
    error "DISCONNECT_PEER_BY_ID failed", error = error
    return err(error)
  return ok("")

proc waku_disconnect_all_peers(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await self.kernel.disconnectAllPeers()).isOkOr:
    return err(error)
  return ok("")

proc waku_dial_peer(
    self: LogosDelivery, peerMultiAddr: string, protocol: string, timeoutMs: uint32
): Future[Result[string, string]] {.ffi.} =
  (await self.kernel.dialPeer(peerMultiAddr, protocol, int(timeoutMs))).isOkOr:
    error "DIAL_PEER failed", error = error
    return err(error)
  return ok("")

proc waku_dial_peer_by_id(
    self: LogosDelivery, peerId: string, protocol: string, timeoutMs: uint32
): Future[Result[string, string]] {.ffi.} =
  (await self.kernel.dialPeerById(peerId, protocol, int(timeoutMs))).isOkOr:
    error "DIAL_PEER_BY_ID failed", error = error
    return err(error)
  return ok("")

proc waku_get_connected_peers_info(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## returns a JSON string mapping peerIDs to objects with protocols and addresses
  let peers = (await self.kernel.connectedPeersInfo()).valueOr:
    return err(error)

  var peersMap = initTable[string, PeerInfo]()
  for peer in peers:
    peersMap[peer.peerId] =
      PeerInfo(protocols: peer.protocols, addresses: peer.addresses)

  return ok($(%*peersMap))

proc waku_get_connected_peers(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peerIds = (await self.kernel.connectedPeers()).valueOr:
    return err(error)
  return ok(peerIds.join(","))

proc waku_get_peerids_by_protocol(
    self: LogosDelivery, protocol: string
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of peerIDs that mount the given protocol
  let peerIds = (await self.kernel.peerIdsByProtocol(protocol)).valueOr:
    return err(error)
  return ok(peerIds.join(","))
