
# This file contains the base message request type that will be handled
# by the Waku Node thread.

import
  std/json,
  stew/results
import
  chronos
import
  ../../../waku/node/waku_node,
  ../waku_thread

type
  InterThreadRequest* = ref object of RootObj

method process*(self: InterThreadRequest, node: WakuNode):
                Future[Result[string, string]] {.base.} = discard

proc `$`*(self: InterThreadRequest): string =
  return $( %* self )
