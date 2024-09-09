import std/[sequtils, strutils]
import chronicles, chronos, results
import
  ../../../../waku/factory/waku,
  ../../../../waku/node/waku_node,
  ../../../alloc,
  ../../../../waku/node/peer_manager

type PeerManagementMsgType* {.pure.} = enum
  CONNECT_TO
  GET_PEER_IDS_FROM_PEER_STORE
  GET_PEER_IDS_BY_PROTOCOL

type PeerManagementRequest* = object
  operation: PeerManagementMsgType
  peerMultiAddr: cstring
  dialTimeout: Duration
  protocol: cstring

proc createShared*(
    T: type PeerManagementRequest,
    op: PeerManagementMsgType,
    peerMultiAddr = "",
    dialTimeout = chronos.milliseconds(0), ## arbitrary Duration as not all ops needs dialTimeout
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerMultiAddr = peerMultiAddr.alloc()
  ret[].dialTimeout = dialTimeout
  return ret

proc createGetPeerIdsByProtocolRequest*(
    T: type PeerManagementRequest, protocol = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = PeerManagementMsgType.GET_PEER_IDS_BY_PROTOCOL
  ret[].protocol = protocol.alloc()
  return ret

proc destroyShared(self: ptr PeerManagementRequest) =
  if not isNil(self[].peerMultiAddr):
    deallocShared(self[].peerMultiAddr)

  if not isNil(self[].protocol):
    deallocShared(self[].protocol)

  deallocShared(self)

proc connectTo(
    node: WakuNode, peerMultiAddr: string, dialTimeout: Duration
): Result[void, string] =
  let peers = (peerMultiAddr).split(",").mapIt(strip(it))

  # TODO: the dialTimeout is not being used at all!
  let connectFut = node.connectToNodes(peers, source = "static")
  while not connectFut.finished():
    poll()

  if not connectFut.completed():
    let msg = "Timeout expired."
    return err(msg)

  return ok()

proc process*(
    self: ptr PeerManagementRequest, waku: Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of CONNECT_TO:
    let ret = waku.node.connectTo($self[].peerMultiAddr, self[].dialTimeout)
    if ret.isErr():
      return err(ret.error)
  of GET_PEER_IDS_FROM_PEER_STORE:
    ## returns a comma-separated string of peerIDs
    let peerIDs = waku.node.peerManager.peerStore.peers().mapIt($it.peerId).join(",")
    return ok(peerIDs)
  of GET_PEER_IDS_BY_PROTOCOL:
    ## returns a comma-separated string of peerIDs that mount the given protocol
    let (inPeers, outPeers) = waku.node.peerManager.connectedPeers($self[].protocol)
    let allPeerIDs = inPeers & outPeers
    return ok(allPeerIDs.mapIt(it.hex()).join(","))

  return ok("")
