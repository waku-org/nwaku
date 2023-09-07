
{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import
  std/[json,sequtils,times,strformat,options,atomics,strutils,os]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net,
  taskpools/channels_spsc_single
import
  ../../../waku/node/waku_node,
  ../events/[json_error_event,json_message_event,json_base_event],
  ./inter_thread_communication/waku_thread_request,
  ./inter_thread_communication/waku_thread_response

type
  Context* = object
    thread: Thread[(ptr Context)]
    reqChannel: ChannelSPSCSingle[ptr InterThreadRequest]
    respChannel: ChannelSPSCSingle[ptr InterThreadResponse]

var ctx {.threadvar.}: ptr Context

# To control when the thread is running
var running: Atomic[bool]

# Every Nim library must have this function called - the name is derived from
# the `--nimMainPrefix` command line option
proc NimMain() {.importc.}
var initialized: Atomic[bool]

proc waku_init() =
  if not initialized.exchange(true):
    NimMain() # Every Nim library needs to call `NimMain` once exactly
  when declared(setupForeignThreadGc): setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

proc run(ctx: ptr Context) {.thread.} =
  ## This is the worker thread body. This thread runs the Waku node
  ## and attends library user requests (stop, connect_to, etc.)

  var node: WakuNode

  while running.load == true:
    ## Trying to get a request from the libwaku main thread

    var request: ptr InterThreadRequest
    let recvOk = ctx.reqChannel.tryRecv(request)
    if recvOk == true:
      let resultResponse =
        waitFor InterThreadRequest.process(request, addr node)

      ## Converting a `Result` into a thread-safe transferable response type
      let threadSafeResp = InterThreadResponse.createShared(resultResponse)

      ## The error-handling is performed in the main thread
      discard ctx.respChannel.trySend( threadSafeResp )

    poll()

  tearDownForeignThreadGc()

proc createWakuThread*(): Result[void, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.

  waku_init()

  ctx = createShared(Context, 1)

  running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    # and freeShared for typed allocations!
    freeShared(ctx)

    return err("failed to create the Waku thread: " & getCurrentExceptionMsg())

  return ok()

proc stopWakuNodeThread*() =
  running.store(false)
  joinThread(ctx.thread)
  freeShared(ctx)

proc sendRequestToWakuThread*(reqType: RequestType,
                              reqContent: pointer): Result[string, string] =

  let req = InterThreadRequest.createShared(reqType, reqContent)

  ## Sending the request
  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    return err("Couldn't send a request to the waku thread: " & $req[])

  ## Waiting for the response
  var response: ptr InterThreadResponse
  var recvOk = ctx.respChannel.tryRecv(response)
  while recvOk == false:
    recvOk = ctx.respChannel.tryRecv(response)
    os.sleep(1)

  ## Converting the thread-safe response into a managed/CG'ed `Result`
  return InterThreadResponse.process(response)
