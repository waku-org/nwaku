
import
    system,
    std/json
import
    stew/results
import
    ../../waku/common/base64,
    ../../waku/waku_core/message/message,
    ./json_base_event

type
  JsonMessage* = ref object
    # https://rfc.vac.dev/spec/36/#jsonmessage-type
    payload*: Base64String
    contentTopic*: string
    version*: uint
    timestamp*: int64
    ephemeral*: bool

func fromJsonNode*(T: type JsonMessage, jsonContent: JsonNode): JsonMessage =
  # Visit https://rfc.vac.dev/spec/14/ for further details
  JsonMessage(
    payload: Base64String(jsonContent["payload"].getStr()),
    contentTopic: jsonContent["contentTopic"].getStr(),
    version: uint32(jsonContent["version"].getInt()),
    timestamp: int64(jsonContent["timestamp"].getBiggestInt()),
    ephemeral: jsonContent["ephemeral"].getBool()
  )

proc toWakuMessage*(self: JsonMessage): WakuMessage =
  let payloadRes = base64.decode(self.payload)
  if not payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

  WakuMessage(
    payload: payloadRes.value,
    contentTopic: self.contentTopic,
    version: uint32(self.version),
    timestamp: self.timestamp,
    ephemeral: self.ephemeral
  )

proc `%`*(value: Base64String): JsonNode =
  %(value.string)

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
