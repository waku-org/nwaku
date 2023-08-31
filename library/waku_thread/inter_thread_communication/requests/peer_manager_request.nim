
import
  std/[options,sequtils,strutils]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../../waku/node/waku_node

type
  PeerManagementMsgType* = enum
    CONNECT_TO

type
  PeerManagementRequest* = object
    operation: PeerManagementMsgType
    peerMultiAddr: string
    dialTimeout: Duration

proc new*(T: type PeerManagementRequest,
          op: PeerManagementMsgType,
          peerMultiAddr: string,
          dialTimeout: Duration): ptr PeerManagementRequest =

  var ret = cast[ptr PeerManagementRequest](
                      allocShared0(sizeof(PeerManagementRequest)))
  ret[].operation = op
  ret[].peerMultiAddr = peerMultiAddr
  ret[].dialTimeout = dialTimeout
  return ret

proc connectTo(node: WakuNode,
               peerMultiAddr: string,
               dialTimeout: Duration): Result[void, string] =

  let peers = (peerMultiAddr).split(",").mapIt(strip(it))

  # TODO: the dialTimeout is not being used at all!
  let connectFut = node.connectToNodes(peers, source="static")
  while not connectFut.finished():
    poll()

  if not connectFut.completed():
    let msg = "Timeout expired."
    return err(msg)

  return ok()

proc process*(self: ptr PeerManagementRequest,
              node: ptr WakuNode): Future[Result[string, string]] {.async.} =

  defer: deallocShared(self)

  case self.operation:

    of CONNECT_TO:
      let ret = node[].connectTo(self[].peerMultiAddr, self[].dialTimeout)
      if ret.isErr():
        return err(ret.error)

  return ok("")
