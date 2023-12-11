
## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the Waku Thread.

import
  std/json,
  stew/results
import
  chronos
import
  ../../../waku/node/waku_node,
  ./requests/node_lifecycle_request,
  ./requests/peer_manager_request,
  ./requests/protocols/relay_request,
  ./requests/protocols/store_request

type
  RequestType* {.pure.} = enum
    LIFECYCLE,
    PEER_MANAGER,
    RELAY,
    STORE,

type
  InterThreadRequest* = object
    reqType: RequestType
    reqContent: pointer

proc createShared*(T: type InterThreadRequest,
                   reqType: RequestType,
                   reqContent: pointer): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  return ret

proc process*(T: type InterThreadRequest,
              request: ptr InterThreadRequest,
              node: ptr WakuNode):
              Future[Result[string, string]] {.async.} =
  ## Processes the request and deallocates its memory
  defer: deallocShared(request)

  echo "Request received: " & $request[].reqType

  let retFut =
    case request[].reqType
      of LIFECYCLE:
        cast[ptr NodeLifecycleRequest](request[].reqContent).process(node)
      of PEER_MANAGER:
        cast[ptr PeerManagementRequest](request[].reqContent).process(node[])
      of RELAY:
        cast[ptr RelayRequest](request[].reqContent).process(node)
      of STORE:
        cast[ptr StoreRequest](request[].reqContent).process(node)

  return await retFut

proc `$`*(self: InterThreadRequest): string =
  return $self.reqType