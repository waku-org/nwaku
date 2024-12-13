import system, results, std/json
import stew/byteutils
import
  ../../waku/common/base64,
  ../../waku/waku_core/message,
  ../../waku/waku_core/message/message,
  ./json_base_event

type JsonMessage* = ref object # https://rfc.vac.dev/spec/36/#jsonmessage-type
  payload*: Base64String
  contentTopic*: string
  version*: uint
  timestamp*: int64
  ephemeral*: bool
  meta*: Base64String
  proof*: Base64String

func fromJsonNode*(T: type JsonMessage, jsonContent: JsonNode): JsonMessage =
  # Visit https://rfc.vac.dev/spec/14/ for further details
  JsonMessage(
    payload: Base64String(jsonContent["payload"].getStr()),
    contentTopic: jsonContent["contentTopic"].getStr(),
    version: uint32(jsonContent{"version"}.getInt()),
    timestamp: int64(jsonContent{"timestamp"}.getBiggestInt()),
    ephemeral: jsonContent{"ephemeral"}.getBool(),
    meta: Base64String(jsonContent{"meta"}.getStr()),
    proof: Base64String(jsonContent{"proof"}.getStr()),
  )

proc toWakuMessage*(self: JsonMessage): Result[WakuMessage, string] =
  let payload = base64.decode(self.payload).valueOr:
    return err("invalid payload format: " & error)

  let meta = base64.decode(self.meta).valueOr:
    return err("invalid meta format: " & error)

  let proof = base64.decode(self.proof).valueOr:
    return err("invalid proof format: " & error)

  ok(
    WakuMessage(
      payload: payload,
      meta: meta,
      contentTopic: self.contentTopic,
      version: uint32(self.version),
      timestamp: self.timestamp,
      ephemeral: self.ephemeral,
      proof: proof,
    )
  )

proc `%`*(value: Base64String): JsonNode =
  %(value.string)

type JsonMessageEvent* = ref object of JsonEvent
  pubsubTopic*: string
  messageHash*: WakuMessageHash
  wakuMessage*: JsonMessage

proc new*(T: type JsonMessageEvent, pubSubTopic: string, msg: WakuMessage): T =
  # Returns a WakuMessage event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  var payload = newSeq[byte](len(msg.payload))
  if len(msg.payload) != 0:
    copyMem(addr payload[0], unsafeAddr msg.payload[0], len(msg.payload))

  var meta = newSeq[byte](len(msg.meta))
  if len(msg.meta) != 0:
    copyMem(addr meta[0], unsafeAddr msg.meta[0], len(msg.meta))

  var proof = newSeq[byte](len(msg.proof))
  if len(msg.proof) != 0:
    copyMem(addr proof[0], unsafeAddr msg.proof[0], len(msg.proof))

  let msgHash = computeMessageHash(pubSubTopic, msg)

  return JsonMessageEvent(
    eventType: "message",
    pubSubTopic: pubSubTopic,
    messageHash: msgHash,
    wakuMessage: JsonMessage(
      payload: base64.encode(payload),
      contentTopic: msg.contentTopic,
      version: msg.version,
      timestamp: int64(msg.timestamp),
      ephemeral: msg.ephemeral,
      meta: base64.encode(meta),
      proof: base64.encode(proof),
    ),
  )

method `$`*(jsonMessage: JsonMessageEvent): string =
  $(%*jsonMessage)
