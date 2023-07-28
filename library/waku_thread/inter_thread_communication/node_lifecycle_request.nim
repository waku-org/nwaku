
import
  std/options
import
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../waku/v2/node/waku_node,
  ./request,
  ./response

type
  NodeLifecycleMsgType* = enum
    START_NODE
    STOP_NODE

type
  NodeLifecycleRequest* = ref object of InterThreadRequest
    operation: NodeLifecycleMsgType

proc new*(T: type NodeLifecycleRequest,
          op: NodeLifecycleMsgType): T =

  return NodeLifecycleRequest(operation: op)

method process*(self: NodeLifecycleRequest,
                node: WakuNode): Future[InterThreadResponse] {.async.} =
  case self.operation:
    of START_NODE:
      waitFor node.start()

    of STOP_NODE:
      waitFor node.stop()

  return InterThreadResponse(result: ResultType.OK)
