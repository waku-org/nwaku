## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the Waku Thread.

import std/json, results
import chronos
import
  ../../../waku/factory/waku,
  ./requests/node_lifecycle_request,
  ./requests/peer_manager_request,
  ./requests/protocols/relay_request,
  ./requests/protocols/store_request,
  ./requests/protocols/lightpush_request,
  ./requests/debug_node_request,
  ./requests/discovery_request,
  ./requests/ping_request

type RequestType* {.pure.} = enum
  LIFECYCLE
  PEER_MANAGER
  PING
  RELAY
  STORE
  DEBUG
  DISCOVERY
  LIGHTPUSH

type InterThreadRequest* = object
  reqType: RequestType
  reqContent: pointer

proc createShared*(
    T: type InterThreadRequest, reqType: RequestType, reqContent: pointer
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  return ret

proc process*(
    T: type InterThreadRequest, request: ptr InterThreadRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  ## Processes the request and deallocates its memory
  defer:
    deallocShared(request)

  echo "Request received: " & $request[].reqType

  let retFut =
    case request[].reqType
    of LIFECYCLE:
      cast[ptr NodeLifecycleRequest](request[].reqContent).process(waku)
    of PEER_MANAGER:
      cast[ptr PeerManagementRequest](request[].reqContent).process(waku[])
    of PING:
      cast[ptr PingRequest](request[].reqContent).process(waku)
    of RELAY:
      cast[ptr RelayRequest](request[].reqContent).process(waku)
    of STORE:
      cast[ptr StoreRequest](request[].reqContent).process(waku)
    of DEBUG:
      cast[ptr DebugNodeRequest](request[].reqContent).process(waku[])
    of DISCOVERY:
      cast[ptr DiscoveryRequest](request[].reqContent).process(waku)
    of LIGHTPUSH:
      cast[ptr LightpushRequest](request[].reqContent).process(waku)

  return await retFut

proc `$`*(self: InterThreadRequest): string =
  return $self.reqType
