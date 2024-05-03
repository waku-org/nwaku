when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets, strformat, uri, options],
  stew/[byteutils, arrayops],
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import ../../../waku_store/common, ../../../common/base64, ../../../waku_core, ../serdes

#### Types

createJsonFlavor RestJson

Json.setWriter JsonWriter, PreferredOutput = string

#### Type conversion

proc parseHash*(input: Option[string]): Result[Option[WakuMessageHash], string] =
  let base64UrlEncoded =
    if input.isSome():
      input.get()
    else:
      return ok(none(WakuMessageHash))

  if base64UrlEncoded == "":
    return ok(none(WakuMessageHash))

  let base64Encoded = decodeUrl(base64UrlEncoded)

  let decodedBytes = base64.decode(Base64String(base64Encoded)).valueOr:
    return err("waku message hash parsing error: " & error)

  let hash: WakuMessageHash = fromBytes(decodedBytes)

  return ok(some(hash))

proc parseHashes*(input: Option[string]): Result[seq[WakuMessageHash], string] =
  var hashes: seq[WakuMessageHash] = @[]

  if not input.isSome() or input.get() == "":
    return ok(hashes)

  let decodedUrl = decodeUrl(input.get())

  if decodedUrl != "":
    for subString in decodedUrl.split(','):
      let hash = ?parseHash(some(subString))

      if hash.isSome():
        hashes.add(hash.get())

  return ok(hashes)

# Converts a given MessageDigest object into a suitable
# Base64-URL-encoded string suitable to be transmitted in a Rest
# request-response. The MessageDigest is first base64 encoded
# and this result is URL-encoded.
proc toRestStringWakuMessageHash*(self: WakuMessageHash): string =
  let base64Encoded = base64.encode(self)
  encodeUrl($base64Encoded)

## WakuMessage serde

proc writeValue*(
    writer: var JsonWriter, msg: WakuMessage
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()

  writer.writeField("payload", base64.encode(msg.payload))
  writer.writeField("content_topic", msg.contentTopic)

  if msg.meta.len > 0:
    writer.writeField("meta", base64.encode(msg.meta))

  writer.writeField("version", msg.version)
  writer.writeField("timestamp", msg.timestamp)
  writer.writeField("ephemeral", msg.ephemeral)

  if msg.proof.len > 0:
    writer.writeField("proof", base64.encode(msg.proof))

  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var WakuMessage
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    payload: seq[byte]
    contentTopic: ContentTopic
    version: uint32
    timestamp: Timestamp
    ephemeral: bool
    meta: seq[byte]
    proof: seq[byte]

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "WakuMessage")

    case fieldName
    of "payload":
      let base64String = reader.readValue(Base64String)
      payload = base64.decode(base64String).valueOr:
        reader.raiseUnexpectedField("Failed decoding data", "payload")
    of "content_topic":
      contentTopic = reader.readValue(ContentTopic)
    of "version":
      version = reader.readValue(uint32)
    of "timestamp":
      timestamp = reader.readValue(Timestamp)
    of "ephemeral":
      ephemeral = reader.readValue(bool)
    of "meta":
      let base64String = reader.readValue(Base64String)
      meta = base64.decode(base64String).valueOr:
        reader.raiseUnexpectedField("Failed decoding data", "meta")
    of "proof":
      let base64String = reader.readValue(Base64String)
      proof = base64.decode(base64String).valueOr:
        reader.raiseUnexpectedField("Failed decoding data", "proof")
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if payload.len == 0:
    reader.raiseUnexpectedValue("Field `payload` is missing")

  value = WakuMessage(
    payload: payload,
    contentTopic: contentTopic,
    version: version,
    timestamp: timestamp,
    ephemeral: ephemeral,
    meta: meta,
    proof: proof,
  )

## WakuMessageHash serde

proc writeValue*(
    writer: var JsonWriter, value: WakuMessageHash
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("data", base64.encode(value))
  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var WakuMessageHash
) {.gcsafe, raises: [SerializationError, IOError].} =
  var data = none(seq[byte])

  for fieldName in readObjectFields(reader):
    case fieldName
    of "data":
      if data.isSome():
        reader.raiseUnexpectedField("Multiple `data` fields found", "WakuMessageHash")
      let decoded = base64.decode(reader.readValue(Base64String))
      if not decoded.isOk():
        reader.raiseUnexpectedField("Failed decoding data", "WakuMessageHash")
      data = some(decoded.get())
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if data.isNone():
    reader.raiseUnexpectedValue("Field `data` is missing")

  for i in 0 ..< 32:
    value[i] = data.get()[i]

## WakuMessageKeyValue serde

proc writeValue*(
    writer: var JsonWriter, value: WakuMessageKeyValue
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()

  writer.writeField("message_hash", value.messageHash)

  if value.message.isSome():
    writer.writeField("message", value.message.get())

  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var WakuMessageKeyValue
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    messageHash = none(WakuMessageHash)
    message = none(WakuMessage)

  for fieldName in readObjectFields(reader):
    case fieldName
    of "message_hash":
      if messageHash.isSome():
        reader.raiseUnexpectedField(
          "Multiple `message_hash` fields found", "WakuMessageKeyValue"
        )
      messageHash = some(reader.readValue(WakuMessageHash))
    of "message":
      if message.isSome():
        reader.raiseUnexpectedField(
          "Multiple `message` fields found", "WakuMessageKeyValue"
        )
      message = some(reader.readValue(WakuMessage))
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if messageHash.isNone():
    reader.raiseUnexpectedValue("Field `message_hash` is missing")

  value = WakuMessageKeyValue(messageHash: messageHash.get(), message: message)

## StoreQueryResponse serde

proc writeValue*(
    writer: var JsonWriter, value: StoreQueryResponse
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()

  writer.writeField("request_id", value.requestId)

  writer.writeField("status_code", value.statusCode)
  writer.writeField("status_desc", value.statusDesc)

  writer.writeField("messages", value.messages)

  if value.paginationCursor.isSome():
    writer.writeField("pagination_cursor", value.paginationCursor.get())

  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var StoreQueryResponse
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    requestId = none(string)
    code = none(uint32)
    desc = none(string)
    messages = none(seq[WakuMessageKeyValue])
    cursor = none(WakuMessageHash)

  for fieldName in readObjectFields(reader):
    case fieldName
    of "request_id":
      if requestId.isSome():
        reader.raiseUnexpectedField(
          "Multiple `request_id` fields found", "StoreQueryResponse"
        )
      requestId = some(reader.readValue(string))
    of "status_code":
      if code.isSome():
        reader.raiseUnexpectedField(
          "Multiple `status_code` fields found", "StoreQueryResponse"
        )
      code = some(reader.readValue(uint32))
    of "status_desc":
      if desc.isSome():
        reader.raiseUnexpectedField(
          "Multiple `status_desc` fields found", "StoreQueryResponse"
        )
      desc = some(reader.readValue(string))
    of "messages":
      if messages.isSome():
        reader.raiseUnexpectedField(
          "Multiple `messages` fields found", "StoreQueryResponse"
        )
      messages = some(reader.readValue(seq[WakuMessageKeyValue]))
    of "pagination_cursor":
      if cursor.isSome():
        reader.raiseUnexpectedField(
          "Multiple `pagination_cursor` fields found", "StoreQueryResponse"
        )
      cursor = some(reader.readValue(WakuMessageHash))
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `request_id` is missing")

  if code.isNone():
    reader.raiseUnexpectedValue("Field `status_code` is missing")

  if desc.isNone():
    reader.raiseUnexpectedValue("Field `status_desc` is missing")

  if messages.isNone():
    reader.raiseUnexpectedValue("Field `messages` is missing")

  value = StoreQueryResponse(
    requestId: requestId.get(),
    statusCode: code.get(),
    statusDesc: desc.get(),
    messages: messages.get(),
    paginationCursor: cursor,
  )

## StoreRequestRest serde

proc writeValue*(
    writer: var JsonWriter, req: StoreQueryRequest
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()

  writer.writeField("request_id", req.requestId)
  writer.writeField("include_data", req.includeData)

  if req.pubsubTopic.isSome():
    writer.writeField("pubsub_topic", req.pubsubTopic.get())

  writer.writeField("content_topics", req.contentTopics)

  if req.startTime.isSome():
    writer.writeField("start_time", req.startTime.get())

  if req.endTime.isSome():
    writer.writeField("end_time", req.endTime.get())

  writer.writeField("message_hashes", req.messageHashes)

  if req.paginationCursor.isSome():
    writer.writeField("pagination_cursor", req.paginationCursor.get())

  writer.writeField("pagination_forward", req.paginationForward)

  if req.paginationLimit.isSome():
    writer.writeField("pagination_limit", req.paginationLimit.get())

  writer.endRecord()
