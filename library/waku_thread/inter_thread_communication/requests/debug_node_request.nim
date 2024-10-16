import std/json
import chronicles, chronos, results, eth/p2p/discoveryv5/enr, strutils, libp2p/peerid
import ../../../../waku/factory/waku, ../../../../waku/node/waku_node

type DebugNodeMsgType* = enum
  RETRIEVE_LISTENING_ADDRESSES
  RETRIEVE_MY_ENR
  RETRIEVE_MY_PEER_ID

type DebugNodeRequest* = object
  operation: DebugNodeMsgType

proc createShared*(T: type DebugNodeRequest, op: DebugNodeMsgType): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared(self: ptr DebugNodeRequest) =
  deallocShared(self)

proc getMultiaddresses(node: WakuNode): seq[string] =
  return node.info().listenAddresses

proc process*(
    self: ptr DebugNodeRequest, waku: Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of RETRIEVE_LISTENING_ADDRESSES:
    ## returns a comma-separated string of the listen addresses
    return ok(waku.node.getMultiaddresses().join(","))
  of RETRIEVE_MY_ENR:
    return ok(waku.node.enr.toURI())
  of RETRIEVE_MY_PEER_ID:
    return ok($waku.node.peerId())

  error "unsupported operation in DebugNodeRequest"
  return err("unsupported operation in DebugNodeRequest")
