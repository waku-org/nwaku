{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}
{.passl: "-Wl,-soname,libwaku.so"}

import std/[json, sequtils, atomics, times, strformat, options, atomics, strutils, os]
import chronicles, chronos
import
  ../../waku/common/base64,
  ../../waku/waku_core/message/message,
  ../../waku/node/waku_node,
  ../../waku/waku_core/topics/pubsub_topic,
  ../../../waku/waku_relay/protocol,
  ./events/json_base_event,
  ./events/json_message_event,
  ./waku_thread/waku_thread,
  ./waku_thread/inter_thread_communication/requests/node_lifecycle_request,
  ./waku_thread/inter_thread_communication/requests/peer_manager_request,
  ./waku_thread/inter_thread_communication/requests/protocols/relay_request,
  ./waku_thread/inter_thread_communication/requests/protocols/store_request,
  ./waku_thread/inter_thread_communication/requests/debug_node_request,
  ./waku_thread/inter_thread_communication/waku_thread_request,
  ./alloc,
  ./callback

################################################################################
### Wrapper around the waku node
################################################################################

################################################################################
### Exported types

const RET_OK: cint = 0
const RET_ERR: cint = 1
const RET_MISSING_CALLBACK: cint = 2

### End of exported types
################################################################################

################################################################################
### Not-exported components

proc relayEventCallback(ctx: ptr Context): WakuRelayHandler =
  return proc(
      pubsubTopic: PubsubTopic, msg: WakuMessage
  ): Future[system.void] {.async.} =
    # Callback that hadles the Waku Relay events. i.e. messages or errors.
    if isNil(ctx[].eventCallback):
      error "eventCallback is nil"
      return

    if isNil(ctx[].eventUserData):
      error "eventUserData is nil"
      return

    try:
      let event = $JsonMessageEvent.new(pubsubTopic, msg)
      cast[WakuCallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg = "Exception when calling 'eventCallBack': " & getCurrentExceptionMsg()
      cast[WakuCallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

### End of not-exported components
################################################################################

################################################################################
### Library setup

# Every Nim library must have this function called - the name is derived from
# the `--nimMainPrefix` command line option
proc NimMain() {.importc.}

# To control when the library has been initialized
var initialized: Atomic[bool]

proc initDispatcher() {.thread.} =
  ## Begins a never ending global dispatcher poll loop.
  ## Raises different exceptions depending on the platform.
  while initialized.load:
    poll()

### End of library setup
################################################################################


################################################################################
### Exported procs
proc waku_hello() {.dynlib, exportc.} =
  NimMain()
  if not initialized.load:
    initialized.store(true)

    when declared(setupForeignThreadGc):
      setupForeignThreadGc()

    when declared(nimGC_setStackBottom):
      var locals {.volatile, noinit.}: pointer
      locals = addr(locals)
      nimGC_setStackBottom(locals)

    var t: Thread[void]
    createThread(t, initDispatcher)
    sleep(500) # TODO: the dispatcher must be running before any async operation is executed. Is there a way to avoid this sleep?

proc waku_bye() {.dynlib, exportc.} =
  tearDownForeignThreadGc()

proc waku_new(
    configJson: cstring, callback: WakuCallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  ## Creates a new instance of the WakuNode.
  if isNil(callback):
    echo "error: missing callback in waku_new"
    return nil

  ## Create the Waku thread that will keep waiting for req from the main thread.
  var ctx = waku_thread.createWakuThread().valueOr:
    let msg = "Error in createWakuThread: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData
  echo "======================= WAKU_CREATE_NODE!"
  let sendReqRes = waku_thread.sendRequestToWakuThread(
     ctx,
     RequestType.LIFECYCLE,
     NodeLifecycleRequest.createShared(NodeLifecycleMsgType.CREATE_NODE, configJson),
  )
  # echo "======================= REQUEST SENT"
  # if sendReqRes.isErr():
  #   let msg = $sendReqRes.error
  #   echo "======================= ERROR SENDING REQUEST"
  #   callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
  #   return nil
  # echo "======================= SUCCESS SENDING REQUEST"
  return ctx

proc waku_destroy(
    ctx: ptr Context, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  if isNil(callback):
    return RET_MISSING_CALLBACK

  waku_thread.stopWakuThread(ctx).isOkOr:
    let msg = $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_OK

proc waku_version(
    ctx: ptr Context, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  callback(
    RET_OK,
    cast[ptr cchar](WakuNodeVersionString),
    cast[csize_t](len(WakuNodeVersionString)),
    userData,
  )

  return RET_OK

proc waku_set_event_callback(
    ctx: ptr Context, callback: WakuCallBack, userData: pointer
) {.dynlib, exportc.} =
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

proc waku_content_topic(
    ctx: ptr Context,
    appName: cstring,
    appVersion: cuint,
    contentTopicName: cstring,
    encoding: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding

  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  let appStr = appName.alloc()
  let ctnStr = contentTopicName.alloc()
  let encodingStr = encoding.alloc()

  let contentTopic = fmt"/{$appStr}/{appVersion}/{$ctnStr}/{$encodingStr}"
  callback(
    RET_OK, unsafeAddr contentTopic[0], cast[csize_t](len(contentTopic)), userData
  )

  deallocShared(appStr)
  deallocShared(ctnStr)
  deallocShared(encodingStr)

  return RET_OK

proc waku_pubsub_topic(
    ctx: ptr Context, topicName: cstring, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding

  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  let topicNameStr = topicName.alloc()

  let outPubsubTopic = fmt"/waku/2/{$topicNameStr}"
  callback(
    RET_OK, unsafeAddr outPubsubTopic[0], cast[csize_t](len(outPubsubTopic)), userData
  )

  deallocShared(topicNameStr)

  return RET_OK

proc waku_default_pubsub_topic(
    ctx: ptr Context, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic

  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  callback(
    RET_OK,
    cast[ptr cchar](DefaultPubsubTopic),
    cast[csize_t](len(DefaultPubsubTopic)),
    userData,
  )

  return RET_OK

proc waku_relay_publish(
    ctx: ptr Context,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
    timeoutMs: cuint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms

  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  let jwm = jsonWakuMessage.alloc()
  var jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson($jwm)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent)
  except JsonParsingError:
    deallocShared(jwm)
    let msg = fmt"Error parsing json message: {getCurrentExceptionMsg()}"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR
  finally:
    deallocShared(jwm)

  let wakuMessage = jsonMessage.toWakuMessage().valueOr:
    let msg = fmt"Problem building the WakuMessage: {error}"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  let pst = pubSubTopic.alloc()

  let targetPubSubTopic =
    if len(pst) == 0:
      DefaultPubsubTopic
    else:
      $pst

  let sendReqRes = waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(
      RelayMsgType.PUBLISH,
      PubsubTopic($pst),
      WakuRelayHandler(relayEventCallback(ctx)),
      wakuMessage,
    ),
  )
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  let msgHash = $sendReqRes.value
  callback(RET_OK, unsafeAddr msgHash[0], cast[csize_t](len(msgHash)), userData)
  return RET_OK

proc waku_start(
    ctx: ptr Context, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ctx[].userData = userData
  ## TODO: handle the error
  discard waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.LIFECYCLE,
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.START_NODE),
  )

proc waku_stop(
    ctx: ptr Context, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ctx[].userData = userData
  ## TODO: handle the error
  discard waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.LIFECYCLE,
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.STOP_NODE),
  )

proc waku_relay_subscribe(
    ctx: ptr Context, pubSubTopic: cstring, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ctx[].userData = userData

  let pst = pubSubTopic.alloc()
  var cb = relayEventCallback(ctx)
  let sendReqRes = waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(
      RelayMsgType.SUBSCRIBE, PubsubTopic($pst), WakuRelayHandler(cb)
    ),
  )
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_OK

proc waku_relay_unsubscribe(
    ctx: ptr Context, pubSubTopic: cstring, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ctx[].userData = userData

  let pst = pubSubTopic.alloc()

  let sendReqRes = waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(
      RelayMsgType.SUBSCRIBE,
      PubsubTopic($pst),
      WakuRelayHandler(relayEventCallback(ctx)),
    ),
  )
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_OK

proc waku_connect(
    ctx: ptr Context,
    peerMultiAddr: cstring,
    timeoutMs: cuint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  ctx[].userData = userData

  let connRes = waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      PeerManagementMsgType.CONNECT_TO, $peerMultiAddr, chronos.milliseconds(timeoutMs)
    ),
  )
  if connRes.isErr():
    let msg = $connRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_OK

proc waku_store_query(
    ctx: ptr Context,
    queryJson: cstring,
    peerId: cstring,
    timeoutMs: cint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  ctx[].userData = userData

  ## TODO: implement the logic that make the "self" node to act as a Store client

  # if sendReqRes.isErr():
  #   let msg = $sendReqRes.error
  #   callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
  #   return RET_ERR

  return RET_OK

proc waku_listen_addresses(
    ctx: ptr Context, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ctx[].userData = userData

  let connRes = waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.DEBUG,
    DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_LISTENING_ADDRESSES),
  )
  if connRes.isErr():
    let msg = $connRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR
  else:
    let msg = $connRes.value
    callback(RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_OK

### End of exported procs
################################################################################
