
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
  ../memory,
  ../config

type
  Context* = object
    thread: Thread[(ptr Context, cstring)]
    node: WakuNode
    reqChannel: Channel[cstring]
    respChannel: Channel[cstring]

var ctx {.threadvar.}: ptr Context

# To control when the thread is running
var running: Atomic[bool]

type
  WakuCallBack* = proc(msg: ptr cchar, len: csize_t) {.cdecl, gcsafe.}

# May keep a reference to a callback defined externally
var extEventCallback*: WakuCallBack = nil

proc relayEventCallback(pubsubTopic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
# proc relayEventCallback(pubsubTopic: string,
#                         msg: WakuMessage):
#                         Future[void] {.gcsafe, raises: [Defect].} =
  # Callback that hadles the Waku Relay events. i.e. messages or errors.
  if not isNil(extEventCallback):
    try:
      let event = $JsonMessageEvent.new(pubsubTopic, msg)
      extEventCallback(unsafeAddr event[0], cast[csize_t](len(event)))
    except Exception,CatchableError:
      error "Exception when calling 'eventCallBack': " &
            getCurrentExceptionMsg()
  else:
    error "extEventCallback is nil"

proc createNode*(ctx: ptr Context, 
                 configJson: cstring): Result[void, string] =

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

  ctx.node = wakuNodeRes.get()

  if relay:
    waitFor ctx.node.mountRelay()
    ctx.node.peerManager.start()

  return ok()

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

proc run(args: tuple [ctx: ptr Context,
                      configJson: cstring]) {.thread.} =
  # This is the worker thread body. This thread runs the Waku node
  # and attend possible library user requests (stop, connect_to, etc.)
  waku_init()

  while running.load == true:
    # Trying to get a request from the libwaku main thread
    let req = args.ctx.reqChannel.tryRecv()
    if req[0] == true:

      if req[1] == "waku_new":
        let ret = createNode(args.ctx, args.configJson)
        if ret.isErr():
          let msg = "ERROR: " & ret.error
          args.ctx.respChannel.send(cast[cstring](msg))

      if req[1] == "waku_start":
        # TODO: wait the future properly
        discard args.ctx.node.start()

      if req[1] == "waku_connect":
        discard args.ctx.node.connectToNodes(@["/ip4/127.0.0.1/tcp/60000/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN"], source="static")

      if req[1] == "waku_subscribe":
        let a = PubsubTopic("/waku/2/default-waku/proto")
        let b = WakuRelayHandler(relayEventCallback)
        args.ctx.node.wakuRelay.subscribe(a, b)

      args.ctx.respChannel.send("OK")

    poll()

proc startThread*(configJson: cstring): Result[void, string] =
  # This proc is called from the main thread and it creates
  # the Waku working thread.
  waku_init()
  ctx = createShared(Context, 1)

  ctx.reqChannel.open()
  ctx.respChannel.open()

  running.store(true)

  let cfgJson = configJson.alloc()

  try:
    createThread(ctx.thread, run, (ctx, cfgJson))
  except ResourceExhaustedError:
    # deallocShared for byte allocations
    deallocShared(cfgJson)
    # and freeShared for typed allocations!
    freeShared(ctx)

    return err("failed to create a thread: " & getCurrentExceptionMsg())

  return ok()

proc stopWakuNodeThread*() =
  running.store(false)
  ctx.reqChannel.send("Close")
  joinThread(ctx.thread)

  ctx.reqChannel.close()
  ctx.respChannel.close()

proc sendRequestToWakuThread*(req: cstring,
                              timeoutMs: int = 300_000):
                              Result[string, string] =

  ctx.reqChannel.send(req)

  var count = 0
  var resp = ctx.respChannel.tryRecv()
  while resp[0] == false:
    resp = ctx.respChannel.tryRecv()
    os.sleep(1)
    count.inc()

    if count > timeoutMs:
      let msg = "Timeout expired. request: " & $req &
                ". timeout in ms: " & $timeoutMs
      return err(msg)

  return ok($resp[1])

