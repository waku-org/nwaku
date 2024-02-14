
import
    system,
    std/json
import
    ../../waku/common/base64,
    ../../waku/waku_core/message/message,
    ./json_base_event

type
  JsonMessage* = ref object
    # https://rfc.vac.dev/spec/36/#jsonmessage-type
    payload*: Base64String
    contentTopic*: string
    version: uint
    timestamp: int64

func toJsonMessage*(msg: WakuMessage): JsonMessage =
  JsonMessage(
    payload: base64.encode(msg.payload),
    contentTopic: msg.contentTopic,
    version: msg.version,
    timestamp: msg.timestamp
  )

proc `%`*(value: Base64String): JsonNode =
  %(value.string)

proc fromJson*(n: JsonNode, argName: string, value: var Base64String) =
  value = Base64String(n.getStr())

type JsonMessageEvent* = ref object of JsonEvent
    pubsubTopic*: string
    messageId*: string
    wakuMessage*: JsonMessage

proc new*(T: type JsonMessageEvent,
          pubSubTopic: string,
          msg: WakuMessage): T =
  # Returns a WakuMessage event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  var payload = newSeq[byte](len(msg.payload))
  copyMem(addr payload[0], unsafeAddr msg.payload[0], len(msg.payload))

  return JsonMessageEvent(
    eventType: "message",
    pubSubTopic: pubSubTopic,
    messageId: "TODO",
    wakuMessage: JsonMessage(
        payload: base64.encode(payload),
        contentTopic: msg.contentTopic,
        version: msg.version,
        timestamp: int64(msg.timestamp)
    )
  )

method `$`*(jsonMessage: JsonMessageEvent): string =
  $( %* jsonMessage )
