{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import
  waku/factory/waku,
  ./inter_thread_communication/[waku_thread_request, requests/debug_node_request],
  ../ffi_types

type WakuContext* = object
  wakuThread: Thread[(ptr WakuContext)]
  watchdogThread: Thread[(ptr WakuContext)]
    # monitors the Waku thread and notifies the Waku SDK consumer if it hangs
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr WakuThreadRequest]
  reqSignal: ThreadSignalPtr
    # to inform The Waku Thread (a.k.a TWT) that a new request is sent
  reqReceivedSignal: ThreadSignalPtr
    # to inform the main thread that the request is rx by TWT
  userData*: pointer
  eventCallback*: pointer
  eventUserdata*: pointer
  running: Atomic[bool] # To control when the thread is running

const git_version* {.strdefine.} = "n/a"
const versionString = "version / git commit hash: " & waku.git_version

proc sendRequestToWakuThread*(
    ctx: ptr WakuContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: WakuCallBack,
    userData: pointer,
): Result[void, string] =
  let req = WakuThreadRequest.createShared(reqType, reqContent, callback, userData)

  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  ctx.lock.acquire()
  defer:
    ctx.lock.release()
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

  ## wait until the Waku Thread properly received the request
  let res = ctx.reqReceivedSignal.waitSync()
  if res.isErr():
    deallocShared(req)
    return err("Couldn't receive reqReceivedSignal signal")

  ## Notice that in case of "ok", the deallocShared(req) is performed by the Waku Thread in the
  ## process proc. See the 'waku_thread_request.nim' module for more details.
  ok()

proc watchdogThreadBody(ctx: ptr WakuContext) {.thread.} =
  ## Watchdog thread that monitors the Waku thread and notifies the library user if it hangs.

  let watchdogRun = proc(ctx: ptr WakuContext) {.async.} =
    const WatchdogTimeinterval = 1.seconds
    while true:
      if ctx.running.load == false:
        break

      let watchdogFut = newFuture[void]("watchdog")

      let wakuCallback = proc(
          callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
      ) {.cdecl, gcsafe, raises: [].} =
        let watchdog = cast[Future[void]](userData)
        watchdog.complete()

      sendRequestToWakuThread(
        ctx,
        RequestType.DEBUG,
        DebugNodeRequest.createShared(DebugNodeMsgType.CHECK_WAKU_NOT_BLOCKED),
        wakuCallback,
        addr watchdogFut,
      ).isOkOr:
        discard
        # let msg = "libwaku error: " & $error
        # callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)

      if not await watchdogFut.withTimeout(WatchdogTimeinterval):
        ## If the Waku thread is not responding, we notify the user
        discard
        # let msg = "Waku thread is not responding for " & $WatchdogTimeinterval
        # ctx.eventCallback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx.eventUserdata)

  waitFor watchdogRun(ctx)

proc wakuThreadBody(ctx: ptr WakuContext) {.thread.} =
  ## Waku thread that attends library user requests (stop, connect_to, etc.)

  let wakuRun = proc(ctx: ptr WakuContext) {.async.} =
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

      let fireRes = ctx.reqReceivedSignal.fireSync()
      if fireRes.isErr():
        error "could not fireSync back to requester thread", error = fireRes.error

      ## Handle the request
      asyncSpawn WakuThreadRequest.process(request, addr waku)

  waitFor wakuRun(ctx)

proc createWakuContext*(): Result[ptr WakuContext, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.
  var ctx = createShared(WakuContext, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr")
  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqReceivedSignal ThreadSignalPtr")
  ctx.lock.initLock()

  ctx.running.store(true)

  try:
    createThread(ctx.wakuThread, wakuThreadBody, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err("failed to create the Waku thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.wakuThread, watchdogThreadBody, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err("failed to create the watchdog thread: " & getCurrentExceptionMsg())

  return ok(ctx)

proc destroyWakuThread*(ctx: ptr WakuContext): Result[void, string] =
  ctx.running.store(false)

  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("error in destroyWakuThread: " & $error)
  if not signaledOnTime:
    return err("failed to signal reqSignal on time in destroyWakuThread")

  joinThread(ctx.wakuThread)
  ctx.lock.deinitLock()
  ?ctx.reqSignal.close()
  ?ctx.reqReceivedSignal.close()
  freeShared(ctx)

  return ok()
