
{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import
  std/[json,sequtils,times,strformat,options,atomics,strutils],
  strutils,
  os
import
  chronicles,
  chronos,
  stew/shims/net
import
  ../../waku/common/enr/builder,
  ../../waku/v2/waku_enr/capabilities,
  ../../waku/v2/waku_enr/multiaddr,
  ../../waku/v2/waku_enr/sharding,
  ../../waku/v2/waku_core/message/message,
  ../../waku/v2/waku_core/topics/pubsub_topic,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/node/builder,
  ../../waku/v2/node/config,
  # ../../waku/v2/waku_relay/protocol,
  ./events/[json_error_event,json_message_event,json_base_event],
  ./working_thread/waku_node_thread,
  ./memory

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

# proc relayEventCallback(pubsubTopic: string,
#                         msg: WakuMessage):
#                         Future[void] {.gcsafe, raises: [Defect].}

# proc startNodeAndWaitForever(ctx: ptr Context) {.thread.} =

#   waitFor ctx.node.mountRelay()
#   ctx.node.peerManager.start()

#   waitFor ctx.node.start()

#   ctx.node.wakuRelay.subscribe(PubsubTopic("/waku/2/default-waku/proto"),
#                            WakuRelayHandler(relayEventCallback))

#   let address = "/ip4/127.0.0.1/tcp/60000/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN"
#   let peers = ($address).split(",").mapIt(strip(it))

#   # TODO: the timeoutMs is not being used at all!
#   let connectFut = ctx.node.connectToNodes(peers, source="static")
#   while not connectFut.finished():
#     poll()

#   while true:
#     # echo "JJJJ ", $(ctx[].node)
#     poll()

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

  let startThRes = waku_node_thread.startThread(configJson)
  if startThRes.isErr():
    let msg = "Error in startThread: " & $startThRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR

  let sendReqRes = sendRequestToWakuThread("waku_new")
  if sendReqRes.isErr():
    let msg = "Failed sending waku_new req: " & $sendReqRes.error
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
  waku_node_thread.extEventCallback = callback

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
  return RET_OK

  # if ctx.node.wakuRelay.isNil():
  #   let msg = "Can't publish. WakuRelay is not enabled."
  #   onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
  #   return RET_ERR

  # let pubMsgFut = ctx.node.wakuRelay.publish(targetPubSubTopic, wakuMessage)

  # # With the next loop we convert an asynchronous call into a synchronous one
  # for i in 0 .. timeoutMs:
  #   if pubMsgFut.finished():
  #     break
  #   sleep(1)

  # if pubMsgFut.finished():
  #   let numPeers = pubMsgFut.read()
  #   if numPeers == 0:
  #     let msg = "Message not sent because no peers found."
  #     onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
  #     return RET_ERR
  #   elif numPeers > 0:
  #     # TODO: pending to return a valid message Id (response when all is correct)
  #     let msg = "hard-coded-message-id"
  #     onOkCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
  #     return RET_OK

  # else:
  #   let msg = "Timeout expired"
  #   onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
  #   return RET_ERR

proc waku_start() {.dynlib, exportc.} =
  # createThread(ctx.thread, startNodeAndWaitForever, ctx)
  discard sendRequestToWakuThread("waku_start")
  # if sendReqRes.isErr():
  #   let msg = "Failed sending waku_start req: " & $sendReqRes.error
  #   onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    
  echo "start"

proc waku_stop() {.dynlib, exportc.} =
  # waitFor ctx.node.stop()
  echo "stop"

proc waku_relay_subscribe(
                pubSubTopic: cstring,
                onErrCb: WakuCallBack): cint
                {.dynlib, exportc.} =

  let sendReqRes = sendRequestToWakuThread("waku_subscribe")
  if sendReqRes.isErr():
    let msg = "Failed sending waku_subscribe req: " & $sendReqRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR
  # @params
  #  topic: Pubsub topic to subscribe to. If empty, it subscribes to the default pubsub topic.
#   if isNil(onErrCb):
#     return RET_MISSING_CALLBACK

#   if isNil(extEventCallback):
#     let msg = $"""Cannot subscribe without a callback.
# # Kindly set it with the 'waku_set_relay_callback' function"""
#     onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
#     return RET_MISSING_CALLBACK

#   if ctx.node.wakuRelay.isNil():
#     let msg = $"Cannot subscribe without Waku Relay enabled."
#     onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
#     return RET_ERR

#   let pst = pubSubTopic.alloc()
#   ctx.node.wakuRelay.subscribe(PubsubTopic($pst),
#                            WakuRelayHandler(relayEventCallback))
#   deallocShared(pst)

  return RET_OK

proc waku_relay_unsubscribe(
                pubSubTopic: cstring,
                onErrCb: WakuCallBack): cint
                {.dynlib, exportc.} =
  # @params
  #  topic: Pubsub topic to subscribe to. If empty, it unsubscribes to the default pubsub topic.
#   if isNil(onErrCb):
#     return RET_MISSING_CALLBACK

#   if isNil(extEventCallback):
#     let msg = """Cannot unsubscribe without a callback.
# Kindly set it with the 'waku_set_relay_callback' function"""
#     onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
#     return RET_MISSING_CALLBACK

#   if ctx.node.wakuRelay.isNil():
#     let msg = "Cannot unsubscribe without Waku Relay enabled."
#     onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
#     return RET_ERR

#   let pst = pubSubTopic.alloc()
#   ctx.node.wakuRelay.unsubscribe(PubsubTopic($pst))
#   deallocShared(pst)

  return RET_OK

proc waku_connect(peerMultiAddr: cstring,
                  timeoutMs: cuint,
                  onErrCb: WakuCallBack): cint
                  {.dynlib, exportc.} =

  let sendReqRes = sendRequestToWakuThread("waku_connect")
  if sendReqRes.isErr():
    let msg = "Failed sending waku_connect req: " & $sendReqRes.error
    onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
    return RET_ERR
  # peerMultiAddr: comma-separated list of fully-qualified multiaddresses.
  # var ret = newString(len + 1)
  # if len > 0:
  #   copyMem(addr ret[0], str, len + 1)

  # let address = peerMultiAddr.alloc()
  # let peers = ($address).split(",").mapIt(strip(it))

  # # TODO: the timeoutMs is not being used at all!
  # let connectFut = ctx.node.connectToNodes(peers, source="static")
  # while not connectFut.finished():
  #   poll()

  # deallocShared(address)

  # if not connectFut.completed():
  #   let msg = "Timeout expired."
  #   onErrCb(unsafeAddr msg[0], cast[csize_t](len(msg)))
  #   return RET_ERR

  return RET_OK

### End of exported procs
################################################################################
