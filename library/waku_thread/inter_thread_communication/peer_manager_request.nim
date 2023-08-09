
import
  std/[options,sequtils,strutils]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../waku/node/waku_node,
  ./request

type
  PeerManagementMsgType* = enum
    CONNECT_TO

type
  PeerManagementRequest* = ref object of InterThreadRequest
    operation: PeerManagementMsgType
    peerMultiAddr: string
    dialTimeout: Duration

proc new*(T: type PeerManagementRequest,
          op: PeerManagementMsgType,
          peerMultiAddr: string,
          dialTimeout: Duration): T =

  return PeerManagementRequest(operation: op,
                               peerMultiAddr: peerMultiAddr,
                               dialTimeout: dialTimeout)

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

method process*(self: PeerManagementRequest,
                node: WakuNode): Future[Result[string, string]] {.async.} =

  case self.operation:

    of CONNECT_TO:
      let ret = node.connectTo(self.peerMultiAddr, self.dialTimeout)
      if ret.isErr():
        return err(ret.error)

  return ok("")
