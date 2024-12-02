{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import waku/factory/waku, ./inter_thread_communication/waku_thread_request, ../ffi_types

type WakuContext* = object
  thread: Thread[(ptr WakuContext)]
  reqChannel: ChannelSPSCSingle[ptr WakuThreadRequest]
  reqSignal: ThreadSignalPtr
  userData*: pointer
  eventCallback*: pointer
  eventUserdata*: pointer
  running: Atomic[bool] # To control when the thread is running

const git_version* {.strdefine.} = "n/a"
const versionString = "version / git commit hash: " & waku.git_version

proc runWaku(ctx: ptr WakuContext) {.async.} =
  ## This is the worker body. This runs the Waku node
  ## and attends library user requests (stop, connect_to, etc.)

  var waku: Waku

  while true:
    await ctx.reqSignal.wait()

    if ctx.running.load == false:
      break

    ## Trying to get a request from the libwaku requestor thread
    var request: ptr WakuThreadRequest
    let recvOk = ctx.reqChannel.tryRecv(request)
    if not recvOk:
      error "waku thread could not receive a request"
      continue

    ## Handle the request
    asyncSpawn WakuThreadRequest.process(request, addr waku)

proc run(ctx: ptr WakuContext) {.thread.} =
  ## Launch waku worker
  waitFor runWaku(ctx)

proc createWakuThread*(): Result[ptr WakuContext, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.
  var ctx = createShared(WakuContext, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr")

  ctx.running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    # and freeShared for typed allocations!
    freeShared(ctx)

    return err("failed to create the Waku thread: " & getCurrentExceptionMsg())

  return ok(ctx)

proc destroyWakuThread*(ctx: ptr WakuContext): Result[void, string] =
  ctx.running.store(false)

  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("error in destroyWakuThread: " & $error)
  if not signaledOnTime:
    return err("failed to signal reqSignal on time in destroyWakuThread")

  joinThread(ctx.thread)
  ?ctx.reqSignal.close()
  freeShared(ctx)

  return ok()

proc sendRequestToWakuThread*(
    ctx: ptr WakuContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: WakuCallBack,
    userData: pointer,
): Result[void, string] =
  let req = WakuThreadRequest.createShared(reqType, reqContent, callback, userData)
  ## Sending the request
  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    deallocShared(req)
    return err("Couldn't send a request to the waku thread: " & $req[])

  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    deallocShared(req)
    return err("failed fireSync: " & $fireSyncRes.error)

  if fireSyncRes.get() == false:
    deallocShared(req)
    return err("Couldn't fireSync in time")

  ok()
