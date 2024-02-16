
import
    system,
    std/[json,sequtils]
import
    stew/[byteutils,results]
import
    ../../waku/common/base64,
    ../../waku/waku_core/message,
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
    meta*: Base64String

func fromJsonNode*(T: type JsonMessage, jsonContent: JsonNode): JsonMessage =
  # Visit https://rfc.vac.dev/spec/14/ for further details
  JsonMessage(
    payload: Base64String(jsonContent["payload"].getStr()),
    contentTopic: jsonContent["contentTopic"].getStr(),
    version: uint32(jsonContent["version"].getInt()),
    timestamp: int64(jsonContent["timestamp"].getBiggestInt()),
    ephemeral: jsonContent["ephemeral"].getBool(),
    meta: Base64String(jsonContent["meta"].getStr()),
  )

proc toWakuMessage*(self: JsonMessage): WakuMessage =
  let payloadRes = base64.decode(self.payload)
  if payloadRes.isErr():
    raise newException(ValueError, "invalid payload format: " & payloadRes.error)

  let metaRes = base64.decode(self.meta)
  if metaRes.isErr():
    raise newException(ValueError, "invalid meta format: " & metaRes.error)

  WakuMessage(
    payload: payloadRes.value,
    meta: metaRes.value,
    contentTopic: self.contentTopic,
    version: uint32(self.version),
    timestamp: self.timestamp,
    ephemeral: self.ephemeral
  )

proc `%`*(value: Base64String): JsonNode =
  %(value.string)

proc `%`*(value: WakuMessageHash): JsonNode =
  %(to0xHex(value))

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
  if len(msg.payload) != 0:
    copyMem(addr payload[0], unsafeAddr msg.payload[0], len(msg.payload))

  var meta = newSeq[byte](len(msg.meta))
  if len(msg.meta) != 0:
    copyMem(addr meta[0], unsafeAddr msg.meta[0], len(msg.meta))

  let msgHash = computeMessageHash(pubSubTopic, msg)
  let msgHashHex = to0xHex(msgHash)

  return JsonMessageEvent(
    eventType: "message",
    pubSubTopic: pubSubTopic,
    messageId: msgHashHex,
    wakuMessage: JsonMessage(
        payload: base64.encode(payload),
        contentTopic: msg.contentTopic,
        version: msg.version,
        timestamp: int64(msg.timestamp),
        ephemeral: msg.ephemeral,
        meta: base64.encode(meta),
    )
  )

method `$`*(jsonMessage: JsonMessageEvent): string =
  $( %* jsonMessage )
