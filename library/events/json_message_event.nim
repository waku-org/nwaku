
import
    std/json
import
    ../../waku/v2/waku_core/message/message,
    ./json_base_event

type JsonMessage = ref object
  # https://rfc.vac.dev/spec/36/#jsonmessage-type
  payload: string
  contentTopic: string
  version: uint
  timestamp: int64

type JsonMessageEvent* = ref object of JsonEvent
    pubsubTopic*: string
    messageId*: string
    wakuMessage*: JsonMessage

proc new*(T: type JsonMessageEvent,
          pubSubTopic: string,
          msg: WakuMessage): T =
  # Returns a WakuMessage event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  var payload = newString(len(msg.payload))
  copyMem(addr payload[0], unsafeAddr msg.payload[0], len(msg.payload))

  return JsonMessageEvent(
    eventType: "message",
    pubSubTopic: pubSubTopic,
    messageId: "TODO",
    wakuMessage: JsonMessage(
        payload: payload,
        contentTopic: msg.contentTopic,
        version: msg.version,
        timestamp: int64(msg.timestamp)
    )
  )

method `$`*(jsonMessage: JsonMessageEvent): string =
  $( %* jsonMessage )
