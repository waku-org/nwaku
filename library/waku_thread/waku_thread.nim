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

const git_version* {.strdefine.} = "n/a"
const versionString = "version / git commit hash: " & waku.git_version

# To control when the thread is running
# TODO: this should be part of the context so multiple instances can be executed
var running: Atomic[bool]

proc runWaku(ctx: ptr WakuContext) {.async.} =
  ## This is the worker body. This runs the Waku node
  ## and attends library user requests (stop, connect_to, etc.)
  info "Starting Waku", version = versionString

  var waku: Waku

  while running.load == true:
    await ctx.reqSignal.wait()

    # Trying to get a request from the libwaku main thread
    var request: ptr InterThreadRequest
    let recvOk = ctx.reqChannel.tryRecv(request)
    if recvOk == true:
      let resultResponse = waitFor InterThreadRequest.process(request, addr waku)

      ## Converting a `Result` into a thread-safe transferable response type
      let threadSafeResp = InterThreadResponse.createShared(resultResponse)

      ## The error-handling is performed in the main thread
      discard ctx.respChannel.trySend(threadSafeResp)
      discard ctx.respSignal.fireSync()

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

  running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    # and freeShared for typed allocations!
    freeShared(ctx)

    return err("failed to create the Waku thread: " & getCurrentExceptionMsg())

  return ok(ctx)

proc stopWakuThread*(ctx: ptr WakuContext): Result[void, string] =
  running.store(false)
  let fireRes = ctx.reqSignal.fireSync()
  if fireRes.isErr():
    return err("error in stopWakuThread: " & $fireRes.error)
  discard ctx.reqSignal.close()
  discard ctx.respSignal.close()
  joinThread(ctx.thread)
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
