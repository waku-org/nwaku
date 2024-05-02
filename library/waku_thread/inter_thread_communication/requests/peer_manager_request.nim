import std/[options, sequtils, strutils]
import chronicles, chronos, stew/results, stew/shims/net
import ../../../../waku/factory/waku, ../../../../waku/node/waku_node, ../../../alloc

type PeerManagementMsgType* = enum
  CONNECT_TO

type PeerManagementRequest* = object
  operation: PeerManagementMsgType
  peerMultiAddr: cstring
  dialTimeout: Duration

proc createShared*(
    T: type PeerManagementRequest,
    op: PeerManagementMsgType,
    peerMultiAddr: string,
    dialTimeout: Duration,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerMultiAddr = peerMultiAddr.alloc()
  ret[].dialTimeout = dialTimeout
  return ret

proc destroyShared(self: ptr PeerManagementRequest) =
  deallocShared(self[].peerMultiAddr)
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

  return ok("")
