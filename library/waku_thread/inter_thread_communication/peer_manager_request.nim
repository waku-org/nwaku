
import
  std/[options,sequtils,strutils]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../waku/v2/node/waku_node,
  ./request,
  ./response

type
  PeerManagementMsgType* = enum
    CONNECT_TO

type
  PeerManagementRequest* = ref object of InterThreadRequest
    operation: PeerManagementMsgType
    peerMultiAddr: string
    timeoutMs: cuint

proc new*(T: type PeerManagementRequest,
          op: PeerManagementMsgType,
          peerMultiAddr: string,
          timeoutMs: cuint): T =

  return PeerManagementRequest(operation: op,
                               peerMultiAddr: peerMultiAddr,
                               timeoutMs: timeoutMs)

proc connectTo(node: WakuNode,
               peerMultiAddr: string): Result[void, string] =
    # let sendReqRes = sendRequestToWakuThread("waku_connect")

  let peers = (peerMultiAddr).split(",").mapIt(strip(it))

  # TODO: the timeoutMs is not being used at all!
  let connectFut = node.connectToNodes(peers, source="static")
  while not connectFut.finished():
    poll()

  if not connectFut.completed():
    let msg = "Timeout expired."
    return err(msg)

  return ok()

method process*(self: PeerManagementRequest,
                node: WakuNode): Future[InterThreadResponse] {.async.} =
  case self.operation:
    of CONNECT_TO:
      let ret = node.connectTo(self.peerMultiAddr)
      if ret.isErr():
        return InterThreadResponse(result: ResultType.OK,
                                   message: ret.error)

  return InterThreadResponse(result: ResultType.OK)
