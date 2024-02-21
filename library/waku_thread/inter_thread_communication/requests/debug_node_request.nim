
import
  std/[options,sequtils,strutils,json]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../../waku/node/waku_node,
  ../../../alloc

type
  DebugNodeMsgType* = enum
    RETRIEVE_LISTENING_ADDRESSES

type
  DebugNodeRequest* = object
    operation: DebugNodeMsgType

proc createShared*(T: type DebugNodeRequest,
                   op: DebugNodeMsgType): ptr type T =

  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared(self: ptr DebugNodeRequest) =
  deallocShared(self)

proc getMultiaddresses(node: WakuNode): seq[string] =
  return node.info().listenAddresses

proc process*(self: ptr DebugNodeRequest,
              node: WakuNode): Future[Result[string, string]] {.async.} =

  defer: destroyShared(self)

  case self.operation:
    of RETRIEVE_LISTENING_ADDRESSES:
      return ok($( %* node.getMultiaddresses()))

  return err("unsupported operation in DebugNodeRequest")

