{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[json, sequtils, times, strformat, options, atomics, strutils, os]
import
  chronicles,
  chronos,
  chronos/threadsync,
  taskpools/channels_spsc_single,
  stew/results,
  stew/shims/net
import
  ../../../waku/factory/waku,
  ../events/[json_message_event, json_base_event],
  ./inter_thread_communication/waku_thread_request,
  ./inter_thread_communication/waku_thread_response

type Context* = object
  thread: Thread[(ptr Context)]
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
var running: Atomic[bool]

# Every Nim library must have this function called - the name is derived from
# the `--nimMainPrefix` command line option
proc NimMain() {.importc.}
var initialized: Atomic[bool]

proc waku_init() =
  if not initialized.exchange(true):
    NimMain() # Every Nim library needs to call `NimMain` once exactly
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

proc run(ctx: ptr Context) {.thread.} =
  ## This is the worker thread body. This thread runs the Waku node
  ## and attends library user requests (stop, connect_to, etc.)
  info "Starting Waku", version = versionString

  var waku: Waku

  while running.load == true:
    ## Trying to get a request from the libwaku main thread

    var request: ptr InterThreadRequest
    waitFor ctx.reqSignal.wait()
    let recvOk = ctx.reqChannel.tryRecv(request)
    if recvOk == true:
      let resultResponse = waitFor InterThreadRequest.process(request, addr waku)

      ## Converting a `Result` into a thread-safe transferable response type
      let threadSafeResp = InterThreadResponse.createShared(resultResponse)

      ## The error-handling is performed in the main thread
      discard ctx.respChannel.trySend(threadSafeResp)
      discard ctx.respSignal.fireSync()

  tearDownForeignThreadGc()

proc createWakuThread*(): Result[ptr Context, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.

  waku_init()

  var ctx = createShared(Context, 1)
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

proc stopWakuThread*(ctx: ptr Context): Result[void, string] =
  running.store(false)
  let fireRes = ctx.reqSignal.fireSync()
  if fireRes.isErr():
    return err("error in stopWakuThread: " & $fireRes.error)
  joinThread(ctx.thread)
  discard ctx.reqSignal.close()
  discard ctx.respSignal.close()
  freeShared(ctx)
  return ok()

proc sendRequestToWakuThread*(
    ctx: ptr Context, reqType: RequestType, reqContent: pointer
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

  ## Waiting for the response
  waitFor ctx.respSignal.wait()

  var response: ptr InterThreadResponse
  var recvOk = ctx.respChannel.tryRecv(response)
  if recvOk == false:
    return err("Couldn't receive response from the waku thread: " & $req[])

  ## Converting the thread-safe response into a managed/CG'ed `Result`
  return InterThreadResponse.process(response)
