
{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import
  std/[json,sequtils,times,strformat,options,atomics,strutils],
  strutils
import
  chronicles,
  chronos
import
  ../../waku/v2/waku_core/message/message,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/waku_core/topics/pubsub_topic,
  ../../../waku/v2/waku_relay/protocol,
  ./events/json_message_event,
  ./waku_thread/waku_thread as waku_thread_module,
  ./waku_thread/inter_thread_communication/node_lifecycle_request,
  ./waku_thread/inter_thread_communication/peer_manager_request,
  ./waku_thread/inter_thread_communication/protocols/relay_request,
  ./alloc

################################################################################
### Wrapper around the waku node
################################################################################

################################################################################
### Exported types

const RET_OK: cint = 0
const RET_ERR: cint = 1
const RET_MISSING_CALLBACK: cint = 2

type
  WakuCallBack* = proc(msg: ptr cchar, len: csize_t) {.cdecl, gcsafe.}

### End of exported types
################################################################################

################################################################################
### Not-exported components

# May keep a reference to a callback defined externally
var extEventCallback*: WakuCallBack = nil

proc relayEventCallback(pubsubTopic: PubsubTopic,
                        msg: WakuMessage): Future[void] {.async, gcsafe.} =
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

### End of not-exported components
################################################################################

################################################################################
### Exported procs

proc waku_new(configJson: cstring,
              onErrCb: WakuCallback): cint
              {.dynlib, exportc, cdecl.} =
  # Creates a new instance of the WakuNode.
  # Notice that the ConfigNode type is also exported and available for users.

  if isNil(onErrCb):
    return RET_MISSING_CALLBACK

  let createThRes = waku_thread_module.createWakuThread(configJson)
  if createThRes.isErr():
    let msg = "Error in createWakuThread: " & $createThRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_version(onOkCb: WakuCallBack): cint {.dynlib, exportc.} =
  if isNil(onOkCb):
    return RET_MISSING_CALLBACK

  onOkCb(cast[ptr cchar](WakuNodeVersionString),
         cast[csize_t](len(WakuNodeVersionString)))

  return RET_OK

proc waku_set_event_callback(callback: WakuCallBack) {.dynlib, exportc.} =
  extEventCallback = callback

proc waku_content_topic(appName: cstring,
                        appVersion: cuint,
                        contentTopicName: cstring,
                        encoding: cstring,
                        onOkCb: WakuCallBack): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding

  if isNil(onOkCb):
    return RET_MISSING_CALLBACK

  let appStr = appName.alloc()
  let ctnStr = contentTopicName.alloc()
  let encodingStr = encoding.alloc()

  let contentTopic = fmt"/{$appStr}/{appVersion}/{$ctnStr}/{$encodingStr}"
  onOkCb(unsafeAddr contentTopic[0], cast[csize_t](len(contentTopic)))

  deallocShared(appStr)
  deallocShared(ctnStr)
  deallocShared(encodingStr)

  return RET_OK

proc waku_pubsub_topic(topicName: cstring,
                       onOkCb: WakuCallBack): cint {.dynlib, exportc, cdecl.} =
  if isNil(onOkCb):
    return RET_MISSING_CALLBACK

  let topicNameStr = topicName.alloc()

  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding
  let outPubsubTopic = fmt"/waku/2/{$topicNameStr}"
  onOkCb(unsafeAddr outPubsubTopic[0], cast[csize_t](len(outPubsubTopic)))

  deallocShared(topicNameStr)

  return RET_OK

proc waku_default_pubsub_topic(onOkCb: WakuCallBack): cint {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic
  if isNil(onOkCb):
    return RET_MISSING_CALLBACK

  onOkCb(cast[ptr cchar](DefaultPubsubTopic),
         cast[csize_t](len(DefaultPubsubTopic)))

  return RET_OK

proc waku_relay_publish(pubSubTopic: cstring,
                        jsonWakuMessage: cstring,
                        timeoutMs: cuint,
                        onOkCb: WakuCallBack,
                        onErrCb: WakuCallBack): cint

                        {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms

  if isNil(onOkCb) or isNil(onErrCb):
    return RET_MISSING_CALLBACK

  let jwm = jsonWakuMessage.alloc()
  var jsonContent:JsonNode
  try:
    jsonContent = parseJson($jwm)
  except JsonParsingError:
    deallocShared(jwm)
    let msg = fmt"Error parsing json message: {getCurrentExceptionMsg()}"
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
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
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  let pst = pubSubTopic.alloc()

  let targetPubSubTopic = if len(pst) == 0:
                            DefaultPubsubTopic
                          else:
                            $pst

  let sendReqRes = waku_thread_module.sendRequestToWakuThread(
                        RelayRequest.new(RelayMsgType.PUBLISH,
                                         PubsubTopic($pst),
                                         WakuRelayHandler(relayEventCallback),
                                         wakuMessage))
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_start() {.dynlib, exportc.} =
  discard waku_thread_module.sendRequestToWakuThread(
                                NodeLifecycleRequest.new(
                                          NodeLifecycleMsgType.START_NODE))

proc waku_stop() {.dynlib, exportc.} =
  discard waku_thread_module.sendRequestToWakuThread(
                                NodeLifecycleRequest.new(
                                          NodeLifecycleMsgType.STOP_NODE))

proc waku_relay_subscribe(
                pubSubTopic: cstring,
                onErrCb: WakuCallBack): cint
                {.dynlib, exportc.} =

  let pst = pubSubTopic.alloc()
  let sendReqRes = waku_thread_module.sendRequestToWakuThread(
                        RelayRequest.new(RelayMsgType.SUBSCRIBE,
                                         PubsubTopic($pst),
                                         WakuRelayHandler(relayEventCallback)))
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_relay_unsubscribe(
                pubSubTopic: cstring,
                onErrCb: WakuCallBack): cint
                {.dynlib, exportc.} =

  let pst = pubSubTopic.alloc()
  let sendReqRes = waku_thread_module.sendRequestToWakuThread(
                        RelayRequest.new(RelayMsgType.UNSUBSCRIBE,
                                         PubsubTopic($pst),
                                         WakuRelayHandler(relayEventCallback)))
  deallocShared(pst)

  if sendReqRes.isErr():
    let msg = $sendReqRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

proc waku_connect(peerMultiAddr: cstring,
                  timeoutMs: cuint,
                  onErrCb: WakuCallBack): cint
                  {.dynlib, exportc.} =

  let connRes = waku_thread_module.sendRequestToWakuThread(
                                  PeerManagementRequest.new(
                                            PeerManagementMsgType.CONNECT_TO,
                                            $peerMultiAddr,
                                            chronos.milliseconds(timeoutMs)))
  if connRes.isErr():
    let msg = $connRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  return RET_OK

### End of exported procs
################################################################################
