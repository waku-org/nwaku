{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import
  waku/factory/waku,
  ./inter_thread_communication/waku_thread_request,
  ./inter_thread_communication/waku_thread_response

type WakuContext* = object
  thread: Thread[(ptr WakuContext)]
  reqChannel: ChannelSPSCSingle[ptr InterThreadRequest]
  reqSignal: ThreadSignalPtr
  respChannel: ChannelSPSCSingle[ptr InterThreadResponse]
  respSignal: ThreadSignalPtr
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
    var request: ptr InterThreadRequest
    let recvOk = ctx.reqChannel.tryRecv(request)
    if not recvOk:
      error "waku thread could not receive a request"
      continue

    ## Handle the request
    let resultResponse = waitFor InterThreadRequest.process(request, addr waku)

    ## Converting a `Result` into a thread-safe transferable response type
    let threadSafeResp = InterThreadResponse.createShared(resultResponse)

    ## Send the response back to the thread that sent the request
    let sentOk = ctx.respChannel.trySend(threadSafeResp)
    if not sentOk:
      error "could not send a request to the requester thread",
        original_request = $request[]

    let fireRes = ctx.respSignal.fireSync()
    if fireRes.isErr():
      error "could not fireSync back to requester thread",
        original_request = $request[], error = fireRes.error

proc run(ctx: ptr WakuContext) {.thread.} =
  ## Launch waku worker
  waitFor runWaku(ctx)

proc createWakuThread*(): Result[ptr WakuContext, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.
  var ctx = createShared(WakuContext, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr")
  ctx.respSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create respSignal ThreadSignalPtr")

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
  ?ctx.respSignal.close()
  freeShared(ctx)

  return ok()

proc sendRequestToWakuThread*(
    ctx: ptr WakuContext, reqType: RequestType, reqContent: pointer
): Result[string, string] =
  let req = InterThreadRequest.createShared(reqType, reqContent)
  ## Sending the request
  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    return err("Couldn't send a request to the waku thread: " & $req[])

  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    return err("failed fireSync: " & $fireSyncRes.error)

  if fireSyncRes.get() == false:
    return err("Couldn't fireSync in time")

  # Waiting for the response
  let res = waitSync(ctx.respSignal)
  if res.isErr():
    return err("Couldnt receive response signal")

  var response: ptr InterThreadResponse
  var recvOk = ctx.respChannel.tryRecv(response)
  if recvOk == false:
    return err("Couldn't receive response from the waku thread: " & $req[])

  ## Converting the thread-safe response into a managed/CG'ed `Result`
  return InterThreadResponse.process(response)
