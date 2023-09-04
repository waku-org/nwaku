
{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import
  std/[json,sequtils,times,strformat,options,atomics,strutils,os]
import
  chronicles,
  chronos,
  stew/results,
  stew/shims/net
import
  ../../../waku/node/waku_node,
  ../events/[json_error_event,json_message_event,json_base_event],
  ./inter_thread_communication/request

type
  Context* = object
    thread: Thread[(ptr Context)]
    reqChannel: Channel[InterThreadRequest]
    respChannel: Channel[Result[string, string]]
    node: WakuNode

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
    let req = ctx.reqChannel.tryRecv()
    if req[0] == true:
      let response = waitFor req[1].process(addr node)
      ctx.respChannel.send( response )

    poll()

  tearDownForeignThreadGc()

proc createWakuThread*(): Result[void, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.

  waku_init()

  ctx = createShared(Context, 1)
  ctx.reqChannel.open()
  ctx.respChannel.open()

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

  ctx.reqChannel.close()
  ctx.respChannel.close()

  freeShared(ctx)

proc sendRequestToWakuThread*(req: InterThreadRequest): Result[string, string] =

  ctx.reqChannel.send(req)

  var resp = ctx.respChannel.tryRecv()
  while resp[0] == false:
    resp = ctx.respChannel.tryRecv()
    os.sleep(1)

  return resp[1]

