
import
  std/[sequtils,times,strformat,json],
  os
import
  chronicles,
  chronos
import
  ../../waku/v2/waku_core/message/codec,
  ../../waku/v2/waku_core/message/message,
  ../../waku/v2/waku_core/topics/pubsub_topic,
  ../../apps/wakunode2/wakunode2,
  events/[json_error_event,json_message_event,json_signal_event]


################################################################################
### Wrapper around the waku node
################################################################################

################################################################################
### Not exported components

type
  EventCallback = proc(signal: cstring) {.cdecl, gcsafe, raises: [Defect].}

var eventCallback:EventCallback = nil

proc callbackHandler(pubsubTopic: string, data: seq[byte]): Future[void] {.gcsafe, raises: [Defect].} =
  if eventCallback != nil:
    let msg = WakuMessage.decode(data)
    var event: JsonSignal
    if msg.isOk():
      event = JsonMessageEvent.new(pubsubTopic, msg.value)
    else:
      let errorMsg = string("Error decoding message.") & $msg.error
      event = JsonErrorEvent.new(errorMsg)

    try:
      eventCallback(cstring($event))
    except Exception:
      error "Exception when calling 'eventCallBack': " &
            getCurrentExceptionMsg()
  else:
    error "eventCallback is nil"

  var retFut = newFuture[void]()
  retFut.complete()
  return retFut

proc okResp(message: string): string =
  $(%* { "result": message })

proc errResp(message: string): string =
  # Convers an error message into an error-JsonResponse
  # {
  #   error: string;
  # }
  return $(%* { "error": message })

################################################################################
### Exported components

proc waku_version(): cstring {.dynlib, exportc.} =
  return wakuNode2VersionString

proc waku_set_event_callback(callback: EventCallback) {.dynlib, exportc.} =
  eventCallback = callback

proc waku_content_topic(appName: cstring,
                        appVersion: uint,
                        contentTopicName: cstring,
                        encoding: cstring,
                        outContentTopic: var string) {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding
  outContentTopic = fmt"{appName}/{appVersion}/{contentTopicName}/{encoding}"

proc waku_pubsub_topic(topicName: cstring, encoding: cstring, outPubsubTopic: var string) {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding
  outPubsubTopic = fmt"/waku/2/{topicName}/{encoding}"

proc waku_default_pubsub_topic(defPubsubTopic: var string) {.dynlib, exportc.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic
  defPubsubTopic = DefaultPubsubTopic

proc waku_relay_publish(pubSubTopic: cstring,
                        jsonWakuMessage: cstring,
                        timeoutMs: int,
                        jsonResp: var string)

                        {.dynlib, exportc, cdecl.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms

  var jsonContent:JsonNode
  try:
    jsonContent = parseJson($jsonWakuMessage)
  except JsonParsingError:
    jsonResp = errResp (fmt"Problem parsing json message. {getCurrentExceptionMsg()}")
    return

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
    jsonResp = errResp(fmt"Problem building the WakuMessage. {getCurrentExceptionMsg()}")
    return

  let targetPubSubTopic = if $pubSubTopic == "":
                            cstring(DefaultPubsubTopic)
                          else:
                            pubSubTopic

  let pubMsgFut = wakunode2.publishMessage(targetPubSubTopic, wakuMessage)

  # With the next loop we convert an asynchronous call into a synchronous one
  for i in 0 .. timeoutMs:
    if pubMsgFut.finished():
      break
    sleep(1)

  if pubMsgFut.finished():
    let numPeers = pubMsgFut.read()
    if numPeers == 0:
      jsonResp = errResp("Message not sent because no peers found")
    elif numPeers > 0:
      # TODO: pending to return a valid message Id (response when all is correct)
      jsonResp = okResp("hard-coded-message-id")

  else:
    jsonResp = errResp("Timeout expired")

proc waku_new(config_file: cstring) {.dynlib, exportc.} =
  wakunode2.init($config_file)

proc waku_start() {.dynlib, exportc.} =
  wakunode2.startNode()

proc waku_relay_subscribe(pubSubTopic: cstring, jsonResp: var string) {.dynlib, exportc.} =
  # @params
  #  topic: Pubsub topic to subscribe to. If empty, it subscribes to the default pubsub topic.
  if eventCallback == nil:
    jsonResp = errResp("Cannot subcribe without a callback. Kindly set it with the 'waku_set_event_callback' function")
    return

  wakunode2.subscribeCallbackToTopic(pubSubTopic, callbackHandler)
  # TODO: enhance the feedback in case of error
  jsonResp = okResp("true")

proc waku_relay_unsubscribe(pubSubTopic: cstring, jsonResp: var string) {.dynlib, exportc.} =
  # @params
  #  topic: Pubsub topic to subscribe to. If empty, it unsubscribes to the default pubsub topic.
  wakunode2.unsubscribeCallbackFromTopic(pubSubTopic, callbackHandler)
  # TODO: enhance the feedback in case of error
  jsonResp = okResp("true")

