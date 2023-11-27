
import
  std/[options,sequtils,strutils]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../../../waku/node/waku_node,
  ../../../../../waku/waku_archive/driver/builder,
  ../../../../../waku/waku_archive/driver,
  ../../../../../waku/waku_archive/retention_policy/builder,
  ../../../../../waku/waku_archive/retention_policy,
  ../../../../alloc,
  ../../../../callback

type
  StoreConfigState* = enum
    STORE_DISABLE
    STORE_ENABLE

type
  StoreReqType* = enum
    CONFIG_STORE
    REMOTE_QUERY ## to perform a query to another Store node
    LOCAL_QUERY ## to retrieve the data from 'self' node

type
  StoreConfigRequest* = object
    storeState: StoreConfigState
    dbUrl: cstring
    retentionPolicy: cstring

type
  StoreQueryRequest* = object
    queryJson: cstring
    peerAddr: cstring
    timeoutMs: cint
    storeCallback: WakuCallBack

type
  StoreRequest* = object
    operation: StoreReqType
    storeReq: pointer

proc createShared*(T: type StoreRequest,
                   operation: StoreReqType,
                   request: pointer): ptr type T =
  var ret = createShared(T)
  ret[].request = request
  return ret

proc createShared*(T: type StoreConfigRequest,
                   storeState: StoreConfigState,
                   dbUrl: cstring,
                   retentionPolicy: cstring): ptr type T =
  var ret = createShared(T)
  ret[].storeState = storeState
  ret[].dbUrl = dbUrl.alloc()
  ret[].retentionPolicy = retentionPolicy.alloc()
  return ret

proc createShared*(T: type StoreQueryRequest,
                   queryJson: cstring,
                   peerAddr: cstring,
                   timeoutMs: cint,
                   storeCallback: WakuCallBack = nil): ptr type T =

  var ret = createShared(T)
  ret[].timeoutMs = timeoutMs
  ret[].queryJson = queryJson.alloc()
  ret[].peerAddr = peerAddr.alloc()
  ret[].storeCallback = storeCallback
  return ret

proc destroyShared(self: ptr StoreConfigRequest) =
  deallocShared(self[].dbUrl)
  deallocShared(self[].retentionPolicy)
  deallocShared(self)

proc destroyShared(self: ptr StoreQueryRequest) =
  deallocShared(self[].queryJson)
  deallocShared(self[].peerAddr)
  deallocShared(self)

proc process(request: ptr StoreConfigRequest,
             node: ptr WakuNode): Future[Result[string, string]] {.async.} =

  defer: destroyShared(request)

  if request[].storeState == STORE_ENABLE:
    ## TODO: the following snippet is duplicated from app.nim
    var onErrAction = proc(msg: string) {.gcsafe, closure.} =
      ## Action to be taken when an internal error occurs during the node run.
      ## e.g. the connection with the database is lost and not recovered.
      error "Unrecoverable error occurred", error = msg

    let dbVacuum: bool = false
    let dbMigration: bool = false
    let maxNumConn: int = 10 ## TODO: get it from user configuration
    # Archive setup
    let archiveDriverRes = ArchiveDriver.new($request[].dbUrl,
                                             dbVacuum,
                                             dbMigration,
                                             maxNumConn,
                                             onErrAction)
    if archiveDriverRes.isErr():
      return err("failed to setup archive driver: " & archiveDriverRes.error)

    let retPolicyRes = RetentionPolicy.new($request[].retentionPolicy)
    if retPolicyRes.isErr():
      return err("failed to create retention policy: " & retPolicyRes.error)

    let mountArcRes = node[].mountArchive(archiveDriverRes.get(),
                                          retPolicyRes.get())
    if mountArcRes.isErr():
      return err("failed to mount waku archive protocol: " & mountArcRes.error)

    # Store setup
    try:
      await node[].mountStore()
    except CatchableError:
      return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

proc process(self: ptr StoreQueryRequest,
             node: ptr WakuNode): Future[Result[string, string]] {.async.} =
  defer: destroyShared(self)

proc process*(self: ptr StoreRequest,
              node: ptr WakuNode): Future[Result[string, string]] {.async.} =

  defer: deallocShared(self)

  case self.operation:
    of CONFIG_STORE:
      return await cast[ptr StoreConfigRequest](self[].storeReq).process(node)
    of REMOTE_QUERY:
      return await cast[ptr StoreQueryRequest](self[].storeReq).process(node)
    of LOCAL_QUERY:
      discard
      # cast[ptr StoreQueryRequest](request[].reqContent).process(node)

  return ok("")
