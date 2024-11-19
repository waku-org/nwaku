{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

when defined(linux):
  {.passl: "-Wl,-soname,libwaku.so".}

import std/[json, atomics, strformat, options, atomics]
import chronicles, chronos
import
  waku/common/base64,
  waku/waku_core/message/message,
  waku/node/waku_node,
  waku/waku_core/topics/pubsub_topic,
  waku/waku_core/subscription/push_handler,
  waku/waku_relay/protocol,
  ./events/json_message_event,
  ./waku_thread/waku_thread,
  ./waku_thread/inter_thread_communication/requests/node_lifecycle_request,
  ./waku_thread/inter_thread_communication/requests/peer_manager_request,
  ./waku_thread/inter_thread_communication/requests/protocols/relay_request,
  ./waku_thread/inter_thread_communication/requests/protocols/store_request,
  ./waku_thread/inter_thread_communication/requests/protocols/lightpush_request,
  ./waku_thread/inter_thread_communication/requests/protocols/filter_request,
  ./waku_thread/inter_thread_communication/requests/debug_node_request,
  ./waku_thread/inter_thread_communication/requests/discovery_request,
  ./waku_thread/inter_thread_communication/requests/ping_request,
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

template foreignThreadGc(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

proc handleRes[T: string | void](
    res: Result[T, string], callback: WakuCallBack, userData: pointer
): cint =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string]. Notice that in case of Result[void, string], it is enough to
  ## just return RET_OK and not provide any additional feedback through the callback.
  if res.isErr():
    foreignThreadGc:
      let msg = "libwaku error: " & $res.error
      callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  foreignThreadGc:
    var msg: cstring = ""
    when T is string:
      msg = res.get().cstring()
    callback(RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
  return RET_OK

proc onReceivedMessage(ctx: ptr WakuContext): WakuRelayHandler =
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
      foreignThreadGc:
        cast[WakuCallBack](ctx[].eventCallback)(
          RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
        )
    except Exception, CatchableError:
      let msg = "Exception when calling 'eventCallBack': " & getCurrentExceptionMsg()
      foreignThreadGc:
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

if defined(android):
  # Redirect chronicles to Android System logs
  when compiles(defaultChroniclesStream.outputs[0].writer):
    defaultChroniclesStream.outputs[0].writer = proc(
        logLevel: LogLevel, msg: LogOutputStr
    ) {.raises: [].} =
      echo logLevel, msg

### End of library setup
################################################################################

################################################################################
### Exported procs
proc waku_setup() {.dynlib, exportc.} =
  NimMain()
  if not initialized.load:
    initialized.store(true)

    when declared(nimGC_setStackBottom):
      var locals {.volatile, noinit.}: pointer
      locals = addr(locals)
      nimGC_setStackBottom(locals)

proc waku_new(
    configJson: cstring, callback: WakuCallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  ## Creates a new instance of the WakuNode.
  if isNil(callback):
    echo "error: missing callback in waku_new"
    return nil

  ## Create the Waku thread that will keep waiting for req from the main thread.
  var ctx = waku_thread.createWakuThread().valueOr:
    foreignThreadGc:
      let msg = "Error in createWakuThread: " & $error
      callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  waku_thread.sendRequestToWakuThread(
    ctx,
    RequestType.LIFECYCLE,
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.CREATE_NODE, configJson),
  ).isOkOr:
    foreignThreadGc:
      let msg = $error
      callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
      return nil

  return ctx

proc waku_destroy(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread.destroyWakuThread(ctx).handleRes(callback, userData)

proc waku_version(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  foreignThreadGc:
    callback(
      RET_OK,
      cast[ptr cchar](WakuNodeVersionString),
      cast[csize_t](len(WakuNodeVersionString)),
      userData,
    )

  return RET_OK

proc waku_set_event_callback(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
) {.dynlib, exportc.} =
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

proc waku_content_topic(
    ctx: ptr WakuContext,
    appName: cstring,
    appVersion: cuint,
    contentTopicName: cstring,
    encoding: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding

  checkLibwakuParams(ctx, callback, userData)

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
    ctx: ptr WakuContext, topicName: cstring, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding

  checkLibwakuParams(ctx, callback, userData)

  let topicNameStr = topicName.alloc()

  let outPubsubTopic = fmt"/waku/2/{$topicNameStr}"
  callback(
    RET_OK, unsafeAddr outPubsubTopic[0], cast[csize_t](len(outPubsubTopic)), userData
  )

  deallocShared(topicNameStr)

  return RET_OK

proc waku_default_pubsub_topic(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic

  checkLibwakuParams(ctx, callback, userData)

  callback(
    RET_OK,
    cast[ptr cchar](DefaultPubsubTopic),
    cast[csize_t](len(DefaultPubsubTopic)),
    userData,
  )

  return RET_OK

proc waku_relay_publish(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
    timeoutMs: cuint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms

  checkLibwakuParams(ctx, callback, userData)

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
    let msg = "Problem building the WakuMessage: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  let pst = pubSubTopic.alloc()
  defer:
    deallocShared(pst)

  let targetPubSubTopic =
    if len(pst) == 0:
      DefaultPubsubTopic
    else:
      $pst

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(
      RelayMsgType.PUBLISH,
      PubsubTopic($pst),
      WakuRelayHandler(onReceivedMessage(ctx)),
      wakuMessage,
    ),
  )
  .handleRes(callback, userData)

proc waku_start(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.LIFECYCLE,
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.START_NODE),
  )
  .handleRes(callback, userData)

proc waku_stop(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.LIFECYCLE,
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.STOP_NODE),
  )
  .handleRes(callback, userData)

proc waku_relay_subscribe(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  let pst = pubSubTopic.alloc()
  defer:
    deallocShared(pst)
  var cb = onReceivedMessage(ctx)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(
      RelayMsgType.SUBSCRIBE, PubsubTopic($pst), WakuRelayHandler(cb)
    ),
  )
  .handleRes(callback, userData)

proc waku_relay_unsubscribe(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  let pst = pubSubTopic.alloc()
  defer:
    deallocShared(pst)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(
      RelayMsgType.SUBSCRIBE,
      PubsubTopic($pst),
      WakuRelayHandler(onReceivedMessage(ctx)),
    ),
  )
  .handleRes(callback, userData)

proc waku_relay_get_num_connected_peers(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  let pst = pubSubTopic.alloc()
  defer:
    deallocShared(pst)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(RelayMsgType.LIST_CONNECTED_PEERS, PubsubTopic($pst)),
  )
  .handleRes(callback, userData)

proc waku_relay_get_num_peers_in_mesh(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  let pst = pubSubTopic.alloc()
  defer:
    deallocShared(pst)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.RELAY,
    RelayRequest.createShared(RelayMsgType.LIST_MESH_PEERS, PubsubTopic($pst)),
  )
  .handleRes(callback, userData)

proc waku_filter_subscribe(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    contentTopics: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.FILTER,
    FilterRequest.createShared(
      FilterMsgType.SUBSCRIBE,
      pubSubTopic,
      contentTopics,
      FilterPushHandler(onReceivedMessage(ctx)),
    ),
  )
  .handleRes(callback, userData)

proc waku_filter_unsubscribe(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    contentTopics: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.FILTER,
    FilterRequest.createShared(FilterMsgType.UNSUBSCRIBE, pubSubTopic, contentTopics),
  )
  .handleRes(callback, userData)

proc waku_filter_unsubscribe_all(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx, RequestType.FILTER, FilterRequest.createShared(FilterMsgType.UNSUBSCRIBE_ALL)
  )
  .handleRes(callback, userData)

proc waku_lightpush_publish(
    ctx: ptr WakuContext,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  checkLibwakuParams(ctx, callback, userData)

  let jwm = jsonWakuMessage.alloc()
  let pst = pubSubTopic.alloc()
  defer:
    deallocShared(jwm)
    deallocShared(pst)

  var jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson($jwm)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent)
  except JsonParsingError:
    let msg = fmt"Error parsing json message: {getCurrentExceptionMsg()}"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  let wakuMessage = jsonMessage.toWakuMessage().valueOr:
    let msg = "Problem building the WakuMessage: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  let targetPubSubTopic =
    if len(pst) == 0:
      DefaultPubsubTopic
    else:
      $pst

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.LIGHTPUSH,
    LightpushRequest.createShared(
      LightpushMsgType.PUBLISH, PubsubTopic($pst), wakuMessage
    ),
  )
  .handleRes(callback, userData)

proc waku_connect(
    ctx: ptr WakuContext,
    peerMultiAddr: cstring,
    timeoutMs: cuint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      PeerManagementMsgType.CONNECT_TO, $peerMultiAddr, chronos.milliseconds(timeoutMs)
    ),
  )
  .handleRes(callback, userData)

proc waku_disconnect_peer_by_id(
    ctx: ptr WakuContext, peerId: cstring, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      op = PeerManagementMsgType.DISCONNECT_PEER_BY_ID, peerId = $peerId
    ),
  )
  .handleRes(callback, userData)

proc waku_dial_peer(
    ctx: ptr WakuContext,
    peerMultiAddr: cstring,
    protocol: cstring,
    timeoutMs: cuint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      op = PeerManagementMsgType.DIAL_PEER,
      peerMultiAddr = $peerMultiAddr,
      protocol = $protocol,
    ),
  )
  .handleRes(callback, userData)

proc waku_dial_peer_by_id(
    ctx: ptr WakuContext,
    peerId: cstring,
    protocol: cstring,
    timeoutMs: cuint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      op = PeerManagementMsgType.DIAL_PEER_BY_ID, peerId = $peerId, protocol = $protocol
    ),
  )
  .handleRes(callback, userData)

proc waku_get_peerids_from_peerstore(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(PeerManagementMsgType.GET_ALL_PEER_IDS),
  )
  .handleRes(callback, userData)

proc waku_get_connected_peers(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(PeerManagementMsgType.GET_CONNECTED_PEERS),
  )
  .handleRes(callback, userData)

proc waku_get_peerids_by_protocol(
    ctx: ptr WakuContext, protocol: cstring, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      op = PeerManagementMsgType.GET_PEER_IDS_BY_PROTOCOL, protocol = $protocol
    ),
  )
  .handleRes(callback, userData)

proc waku_store_query(
    ctx: ptr WakuContext,
    jsonQuery: cstring,
    peerAddr: cstring,
    timeoutMs: cint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.STORE,
    JsonStoreQueryRequest.createShared(jsonQuery, peerAddr, timeoutMs),
  )
  .handleRes(callback, userData)

proc waku_listen_addresses(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.DEBUG,
    DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_LISTENING_ADDRESSES),
  )
  .handleRes(callback, userData)

proc waku_dns_discovery(
    ctx: ptr WakuContext,
    entTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.DISCOVERY,
    DiscoveryRequest.createRetrieveBootstrapNodesRequest(
      DiscoveryMsgType.GET_BOOTSTRAP_NODES, entTreeUrl, nameDnsServer, timeoutMs
    ),
  )
  .handleRes(callback, userData)

proc waku_discv5_update_bootnodes(
    ctx: ptr WakuContext, bootnodes: cstring, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  ## Updates the bootnode list used for discovering new peers via DiscoveryV5
  ## bootnodes - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.DISCOVERY,
    DiscoveryRequest.createUpdateBootstrapNodesRequest(
      DiscoveryMsgType.UPDATE_DISCV5_BOOTSTRAP_NODES, bootnodes
    ),
  )
  .handleRes(callback, userData)

proc waku_get_my_enr(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.DEBUG,
    DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_MY_ENR),
  )
  .handleRes(callback, userData)

proc waku_get_my_peerid(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.DEBUG,
    DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_MY_PEER_ID),
  )
  .handleRes(callback, userData)

proc waku_start_discv5(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx, RequestType.DISCOVERY, DiscoveryRequest.createDiscV5StartRequest()
  )
  .handleRes(callback, userData)

proc waku_stop_discv5(
    ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx, RequestType.DISCOVERY, DiscoveryRequest.createDiscV5StopRequest()
  )
  .handleRes(callback, userData)

proc waku_peer_exchange_request(
    ctx: ptr WakuContext, numPeers: uint64, callback: WakuCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx, RequestType.DISCOVERY, DiscoveryRequest.createPeerExchangeRequest(numPeers)
  )
  .handleRes(callback, userData)

proc waku_ping_peer(
    ctx: ptr WakuContext,
    peerAddr: cstring,
    timeoutMs: cuint,
    callback: WakuCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  checkLibwakuParams(ctx, callback, userData)

  waku_thread
  .sendRequestToWakuThread(
    ctx,
    RequestType.PING,
    PingRequest.createShared(peerAddr, chronos.milliseconds(timeoutMs)),
  )
  .handleRes(callback, userData)

### End of exported procs
################################################################################
