
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
  ../../../waku/common/enr/builder,
  ../../../waku/v2/waku_enr/capabilities,
  ../../../waku/v2/waku_enr/multiaddr,
  ../../../waku/v2/waku_enr/sharding,
  ../../../waku/v2/waku_core/message/message,
  ../../../waku/v2/waku_core/topics/pubsub_topic,
  ../../../waku/v2/node/peer_manager/peer_manager,
  ../../../waku/v2/waku_core,
  ../../../waku/v2/node/waku_node,
  ../../../waku/v2/node/builder,
  ../../../waku/v2/node/config,
  ../../../waku/v2/waku_relay/protocol,
  ../events/[json_error_event,json_message_event,json_base_event],
  ../alloc,
  ./config,
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

proc createNode(configJson: cstring): Result[WakuNode, string] =
  var privateKey: PrivateKey
  var netConfig = NetConfig.init(ValidIpAddress.init("127.0.0.1"),
                                 Port(60000'u16)).value
  var relay: bool
  var topics = @[""]
  var jsonResp: JsonEvent

  let cj = configJson.alloc()

  if not parseConfig($cj,
                     privateKey,
                     netConfig,
                     relay,
                     topics,
                     jsonResp):
    deallocShared(cj)
    return err($jsonResp)

  deallocShared(cj)

  var enrBuilder = EnrBuilder.init(privateKey)

  enrBuilder.withIpAddressAndPorts(
    netConfig.enrIp,
    netConfig.enrPort,
    netConfig.discv5UdpPort
  )

  if netConfig.wakuFlags.isSome():
    enrBuilder.withWakuCapabilities(netConfig.wakuFlags.get())

  enrBuilder.withMultiaddrs(netConfig.enrMultiaddrs)

  let addShardedTopics = enrBuilder.withShardedTopics(topics)
  if addShardedTopics.isErr():
    let msg = "Error setting shared topics: " & $addShardedTopics.error
    return err($JsonErrorEvent.new(msg))

  let recordRes = enrBuilder.build()
  let record =
    if recordRes.isErr():
      let msg = "Error building enr record: " & $recordRes.error
      return err($JsonErrorEvent.new(msg))

    else: recordRes.get()

  var builder = WakuNodeBuilder.init()
  builder.withRng(crypto.newRng())
  builder.withNodeKey(privateKey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig)
  builder.withSwitchConfiguration(
    maxConnections = some(50.int)
  )

  let wakuNodeRes = builder.build()
  if wakuNodeRes.isErr():
    let errorMsg = "failed to create waku node instance: " & wakuNodeRes.error
    return err($JsonErrorEvent.new(errorMsg))

  var newNode = wakuNodeRes.get()

  if relay:
    waitFor newNode.mountRelay()
    newNode.peerManager.start()

  return ok(newNode)

proc run(ctx: ptr Context) {.thread.} =
  ## This is the worker thread body. This thread runs the Waku node
  ## and attends library user requests (stop, connect_to, etc.)

  while running.load == true:
    ## Trying to get a request from the libwaku main thread
    let req = ctx.reqChannel.tryRecv()
    if req[0] == true:
      let response = waitFor req[1].process(ctx.node)
      ctx.respChannel.send( response )

    poll()

  tearDownForeignThreadGc()

proc createWakuThread*(configJson: cstring): Result[void, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.

  waku_init()

  ctx = createShared(Context, 1)
  ctx.reqChannel.open()
  ctx.respChannel.open()

  let newNodeRes = createNode(configJson)
  if newNodeRes.isErr():
    return err(newNodeRes.error)

  ctx.node = newNodeRes.get()

  running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ResourceExhaustedError:
    # and freeShared for typed allocations!
    freeShared(ctx)

    return err("failed to create a thread: " & getCurrentExceptionMsg())

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

