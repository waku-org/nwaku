import chronos, results
import ../../../../../waku/factory/waku, ../../../../alloc, ../../../../callback

type StoreReqType* = enum
  REMOTE_QUERY ## to perform a query to another Store node
  LOCAL_QUERY ## to retrieve the data from 'self' node

type StoreQueryRequest* = object
  queryJson: cstring
  peerAddr: cstring
  timeoutMs: cint
  storeCallback: WakuCallBack

type StoreRequest* = object
  operation: StoreReqType
  storeReq: pointer

proc createShared*(
    T: type StoreRequest, operation: StoreReqType, request: pointer
): ptr type T =
  var ret = createShared(T)
  ret[].request = request
  return ret

proc createShared*(
    T: type StoreQueryRequest,
    queryJson: cstring,
    peerAddr: cstring,
    timeoutMs: cint,
    storeCallback: WakuCallBack = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].timeoutMs = timeoutMs
  ret[].queryJson = queryJson.alloc()
  ret[].peerAddr = peerAddr.alloc()
  ret[].storeCallback = storeCallback
  return ret

proc destroyShared(self: ptr StoreQueryRequest) =
  deallocShared(self[].queryJson)
  deallocShared(self[].peerAddr)
  deallocShared(self)

proc process(
    self: ptr StoreQueryRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

proc process*(
    self: ptr StoreRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    deallocShared(self)

  case self.operation
  of REMOTE_QUERY:
    return await cast[ptr StoreQueryRequest](self[].storeReq).process(waku)
  of LOCAL_QUERY:
    discard
    # cast[ptr StoreQueryRequest](request[].reqContent).process(node)

  return ok("")
