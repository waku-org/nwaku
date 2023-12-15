
{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import
  std/[json,sequtils,times,strformat,options,atomics,strutils]
import
  chronicles,
  chronos
import
  ../../waku/waku_core/message/message,
  ../../waku/node/waku_node,
  ../../waku/waku_core/topics/pubsub_topic,
  ../../../waku/waku_relay/protocol,
  ./events/json_message_event,
  ./waku_thread/waku_thread,
  ./waku_thread/inter_thread_communication/requests/node_lifecycle_request,
  ./waku_thread/inter_thread_communication/requests/peer_manager_request,
  ./waku_thread/inter_thread_communication/requests/protocols/relay_request,
  ./waku_thread/inter_thread_communication/requests/protocols/store_request,
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

# May keep a reference to a callback defined externally
var extEventCallback*: WakuCallBack = nil

proc relayEventCallback(pubsubTopic: PubsubTopic,
                        msg: WakuMessage): Future[void] {.async.} =
  # Callback that hadles the Waku Relay events. i.e. messages or errors.
  if not isNil(extEventCallback):
    try:
      let event = $JsonMessageEvent.new(pubsubTopic, msg)
      extEventCallback(RET_OK, unsafeAddr event[0], cast[csize_t](len(event)))
    except Exception,CatchableError:
      let msg = "Exception when calling 'eventCallBack': " &
                getCurrentExceptionMsg()
      extEventCallback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
  else:
    error "extEventCallback is nil"

### End of not-exported components
################################################################################

################################################################################
### Exported procs

proc waku_new(configJson: cstring,
              callback: WakuCallback,
              userData: pointer): pointer
              {.dynlib, exportc, cdecl.} =
  ## Creates a new instance of the WakuNode.

  if isNil(callback):
    echo "error: missing callback in waku_new"
    return nil

  ## Create the Waku thread that will keep waiting for req from the main thread.
  var ctx = waku_thread.createWakuThread().valueOr:
    let msg = "Error in createWakuThread: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return nil

  ctx.userData = userData

  let sendReqRes = waku_thread.sendRequestToWakuThread(
                                      ctx,
                                      RequestType.LIFECYCLE,
                                      NodeLifecycleRequest.createShared(
                                              NodeLifecycleMsgType.CREATE_NODE,
                                              configJson))
  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return nil

  return ctx

proc waku_version(ctx: ptr ptr Context,
                  callback: WakuCallBack,
                  userData: pointer): cint {.dynlib, exportc.} =

  ctx[][].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  callback(RET_OK, cast[ptr cchar](WakuNodeVersionString),
           cast[csize_t](len(WakuNodeVersionString)))

  return RET_OK

proc waku_set_event_callback(callback: WakuCallBack) {.dynlib, exportc.} =
  extEventCallback = callback

proc waku_content_topic(ctx: ptr ptr Context,
                        appName: cstring,
                        appVersion: cuint,
                        contentTopicName: cstring,
                        encoding: cstring,
                        callback: WakuCallBack,
                        userData: pointer): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding

  ctx[][].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  let appStr = appName.alloc()
  let ctnStr = contentTopicName.alloc()
  let encodingStr = encoding.alloc()

  let contentTopic = fmt"/{$appStr}/{appVersion}/{$ctnStr}/{$encodingStr}"
  callback(RET_OK, unsafeAddr contentTopic[0], cast[csize_t](len(contentTopic)))

  deallocShared(appStr)
  deallocShared(ctnStr)
  deallocShared(encodingStr)

  return RET_OK

proc waku_pubsub_topic(ctx: ptr ptr Context,
                       topicName: cstring,
                       callback: WakuCallBack,
                       userData: pointer): cint {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding

  ctx[][].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  let topicNameStr = topicName.alloc()

  let outPubsubTopic = fmt"/waku/2/{$topicNameStr}"
  callback(RET_OK, unsafeAddr outPubsubTopic[0], cast[csize_t](len(outPubsubTopic)))

  deallocShared(topicNameStr)

  return RET_OK

proc waku_default_pubsub_topic(ctx: ptr ptr Context,
                               callback: WakuCallBack,
                               userData: pointer): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic

  ctx[][].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  callback(RET_OK, cast[ptr cchar](DefaultPubsubTopic), cast[csize_t](len(DefaultPubsubTopic)))

  return RET_OK

proc waku_relay_publish(ctx: ptr ptr Context,
                        pubSubTopic: cstring,
                        jsonWakuMessage: cstring,
                        timeoutMs: cuint,
                        callback: WakuCallBack,
                        userData: pointer): cint

                        {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms

  ctx[][].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

  let jwm = jsonWakuMessage.alloc()
  var jsonContent:JsonNode
  try:
    jsonContent = parseJson($jwm)
  except JsonParsingError:
    deallocShared(jwm)
    let msg = fmt"Error parsing json message: {getCurrentExceptionMsg()}"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  deallocShared(jwm)

  var wakuMessage: WakuMessage
  try:
    var version = 0'u32
    if jsonContent.hasKey("version"):
      version = (uint32) jsonContent["version"].getInt()

    wakuMessage = WakuMessage(
        # Visit https://rfc.vac.dev/spec/14/ for further details
        payload: jsonContent["payload"].getStr().toSeq().mapIt(byte (it)),
        contentTopic: $jsonContent["content_topic"].getStr(),
        version: version,
        timestamp: getTime().toUnix(),
        ephemeral: false
    )
  except KeyError:
    let msg = fmt"Problem building the WakuMessage: {getCurrentExceptionMsg()}"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  let pst = pubSubTopic.alloc()

  let targetPubSubTopic = if len(pst) == 0:
                            DefaultPubsubTopic
                          else:
                            $pst

  let sendReqRes = waku_thread.sendRequestToWakuThread(
                          ctx[],
                          RequestType.RELAY,
                          RelayRequest.createShared(RelayMsgType.PUBLISH,
                                          PubsubTopic($pst),
                                          WakuRelayHandler(relayEventCallback),
                                          wakuMessage))
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_start(ctx: ptr ptr Context,
                callback: WakuCallBack,
                userData: pointer): cint {.dynlib, exportc.} =

  ctx[][].userData = userData
  ## TODO: handle the error
  discard waku_thread.sendRequestToWakuThread(
                                      ctx[],
                                      RequestType.LIFECYCLE,
                                      NodeLifecycleRequest.createShared(
                                              NodeLifecycleMsgType.START_NODE))

proc waku_stop(ctx: ptr ptr Context,
               callback: WakuCallBack,
               userData: pointer): cint {.dynlib, exportc.} =
  ctx[][].userData = userData
  ## TODO: handle the error
  discard waku_thread.sendRequestToWakuThread(
                                      ctx[],
                                      RequestType.LIFECYCLE,
                                      NodeLifecycleRequest.createShared(
                                              NodeLifecycleMsgType.STOP_NODE))

proc waku_relay_subscribe(
                ctx: ptr ptr Context,
                pubSubTopic: cstring,
                callback: WakuCallBack,
                userData: pointer): cint
                {.dynlib, exportc.} =

  ctx[][].userData = userData

  let pst = pubSubTopic.alloc()

  let sendReqRes = waku_thread.sendRequestToWakuThread(
                              ctx[],
                              RequestType.RELAY,
                              RelayRequest.createShared(RelayMsgType.SUBSCRIBE,
                                    PubsubTopic($pst),
                                    WakuRelayHandler(relayEventCallback)))
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_relay_unsubscribe(
                ctx: ptr ptr Context,
                pubSubTopic: cstring,
                callback: WakuCallBack,
                userData: pointer): cint
                {.dynlib, exportc.} =

  ctx[][].userData = userData

  let pst = pubSubTopic.alloc()

  let sendReqRes = waku_thread.sendRequestToWakuThread(
                              ctx[],
                              RequestType.RELAY,
                              RelayRequest.createShared(RelayMsgType.SUBSCRIBE,
                                    PubsubTopic($pst),
                                    WakuRelayHandler(relayEventCallback)))
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_connect(ctx: ptr ptr Context,
                  peerMultiAddr: cstring,
                  timeoutMs: cuint,
                  callback: WakuCallBack,
                  userData: pointer): cint
                  {.dynlib, exportc.} =

  ctx[][].userData = userData

  let connRes = waku_thread.sendRequestToWakuThread(
                                   ctx[],
                                   RequestType.PEER_MANAGER,
                                   PeerManagementRequest.createShared(
                                            PeerManagementMsgType.CONNECT_TO,
                                            $peerMultiAddr,
                                            chronos.milliseconds(timeoutMs)))
  if connRes.isErr():
    let msg = $connRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_store_query(ctx: ptr ptr Context,
                      queryJson: cstring,
                      peerId: cstring,
                      timeoutMs: cint,
                      callback: WakuCallBack,
                      userData: pointer): cint
                      {.dynlib, exportc.} =

  ctx[][].userData = userData

  ## TODO: implement the logic that make the "self" node to act as a Store client

  # if sendReqRes.isErr():
  #   let msg = $sendReqRes.error
  #   callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)))
  #   return RET_ERR

  return RET_OK

### End of exported procs
################################################################################
