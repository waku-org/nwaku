when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets, strformat, uri],
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import
  ../../../waku_store_legacy/common as waku_store_common,
  ../../../common/base64,
  ../../../waku_core,
  ../serdes

#### Types

type
  HistoryCursorRest* = object
    pubsubTopic*: PubsubTopic
    senderTime*: Timestamp
    storeTime*: Timestamp
    digest*: waku_store_common.MessageDigest

  StoreRequestRest* = object
    # inspired by https://github.com/waku-org/nwaku/blob/f95147f5b7edfd45f914586f2d41cd18fb0e0d18/waku/v2//waku_store/common.nim#L52
    pubsubTopic*: Option[PubsubTopic]
    contentTopics*: seq[ContentTopic]
    cursor*: Option[HistoryCursorRest]
    startTime*: Option[Timestamp]
    endTime*: Option[Timestamp]
    pageSize*: uint64
    ascending*: bool

  StoreWakuMessage* = object
    payload*: Base64String
    contentTopic*: Option[ContentTopic]
    version*: Option[uint32]
    timestamp*: Option[Timestamp]
    ephemeral*: Option[bool]
    meta*: Option[Base64String]

  StoreResponseRest* = object # inspired by https://rfc.vac.dev/spec/16/#storeresponse
    messages*: seq[StoreWakuMessage]
    cursor*: Option[HistoryCursorRest]
    # field that contains error information
    errorMessage*: Option[string]

createJsonFlavor RestJson

Json.setWriter JsonWriter, PreferredOutput = string

#### Type conversion

# Converts a URL-encoded-base64 string into a 'MessageDigest'
proc parseMsgDigest*(
    input: Option[string]
): Result[Option[waku_store_common.MessageDigest], string] =
  if not input.isSome() or input.get() == "":
    return ok(none(waku_store_common.MessageDigest))

  let decodedUrl = decodeUrl(input.get())
  let base64Decoded = base64.decode(Base64String(decodedUrl))
  var messageDigest = waku_store_common.MessageDigest()

  if not base64Decoded.isOk():
    return err(base64Decoded.error)

  let base64DecodedArr = base64Decoded.get()
  # Next snippet inspired by "nwaku/waku/waku_archive/archive.nim"
  # TODO: Improve coherence of MessageDigest type
  messageDigest = block:
    var data: array[32, byte]
    for i in 0 ..< min(base64DecodedArr.len, 32):
      data[i] = base64DecodedArr[i]

    waku_store_common.MessageDigest(data: data)

  return ok(some(messageDigest))

# Converts a given MessageDigest object into a suitable
# Base64-URL-encoded string suitable to be transmitted in a Rest
# request-response. The MessageDigest is first base64 encoded
# and this result is URL-encoded.
proc toRestStringMessageDigest*(self: waku_store_common.MessageDigest): string =
  let base64Encoded = base64.encode(self.data)
  encodeUrl($base64Encoded)

proc toWakuMessage*(message: StoreWakuMessage): WakuMessage =
  WakuMessage(
    payload: base64.decode(message.payload).get(),
    contentTopic: message.contentTopic.get(),
    version: message.version.get(),
    timestamp: message.timestamp.get(),
    ephemeral: message.ephemeral.get(),
    meta: message.meta.get(Base64String("")).decode().get(),
  )

# Converts a 'HistoryResponse' object to an 'StoreResponseRest'
# that can be serialized to a json object.
proc toStoreResponseRest*(histResp: HistoryResponse): StoreResponseRest =
  proc toStoreWakuMessage(message: WakuMessage): StoreWakuMessage =
    StoreWakuMessage(
      payload: base64.encode(message.payload),
      contentTopic: some(message.contentTopic),
      version: some(message.version),
      timestamp: some(message.timestamp),
      ephemeral: some(message.ephemeral),
      meta:
        if message.meta.len > 0:
          some(base64.encode(message.meta))
        else:
          none(Base64String)
      ,
    )

  var storeWakuMsgs: seq[StoreWakuMessage]
  for m in histResp.messages:
    storeWakuMsgs.add(m.toStoreWakuMessage())

  var cursor = none(HistoryCursorRest)
  if histResp.cursor.isSome:
    cursor = some(
      HistoryCursorRest(
        pubsubTopic: histResp.cursor.get().pubsubTopic,
        senderTime: histResp.cursor.get().senderTime,
        storeTime: histResp.cursor.get().storeTime,
        digest: histResp.cursor.get().digest,
      )
    )

  StoreResponseRest(messages: storeWakuMsgs, cursor: cursor)

## Beginning of StoreWakuMessage serde

proc writeValue*(
    writer: var JsonWriter, value: StoreWakuMessage
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("payload", $value.payload)
  if value.contentTopic.isSome():
    writer.writeField("contentTopic", value.contentTopic.get())
  if value.version.isSome():
    writer.writeField("version", value.version.get())
  if value.timestamp.isSome():
    writer.writeField("timestamp", value.timestamp.get())
  if value.ephemeral.isSome():
    writer.writeField("ephemeral", value.ephemeral.get())
  if value.meta.isSome():
    writer.writeField("meta", value.meta.get())
  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var StoreWakuMessage
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    payload = none(Base64String)
    contentTopic = none(ContentTopic)
    version = none(uint32)
    timestamp = none(Timestamp)
    ephemeral = none(bool)
    meta = none(Base64String)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "StoreWakuMessage")

    case fieldName
    of "payload":
      payload = some(reader.readValue(Base64String))
    of "contentTopic":
      contentTopic = some(reader.readValue(ContentTopic))
    of "version":
      version = some(reader.readValue(uint32))
    of "timestamp":
      timestamp = some(reader.readValue(Timestamp))
    of "ephemeral":
      ephemeral = some(reader.readValue(bool))
    of "meta":
      meta = some(reader.readValue(Base64String))
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if payload.isNone():
    reader.raiseUnexpectedValue("Field `payload` is missing")

  value = StoreWakuMessage(
    payload: payload.get(),
    contentTopic: contentTopic,
    version: version,
    timestamp: timestamp,
    ephemeral: ephemeral,
    meta: meta,
  )

## End of StoreWakuMessage serde

## Beginning of MessageDigest serde

proc writeValue*(
    writer: var JsonWriter, value: waku_store_common.MessageDigest
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("data", base64.encode(value.data))
  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var waku_store_common.MessageDigest
) {.gcsafe, raises: [SerializationError, IOError].} =
  var data = none(seq[byte])

  for fieldName in readObjectFields(reader):
    case fieldName
    of "data":
      if data.isSome():
        reader.raiseUnexpectedField("Multiple `data` fields found", "MessageDigest")
      let decoded = base64.decode(reader.readValue(Base64String))
      if not decoded.isOk():
        reader.raiseUnexpectedField("Failed decoding data", "MessageDigest")
      data = some(decoded.get())
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if data.isNone():
    reader.raiseUnexpectedValue("Field `data` is missing")

  for i in 0 ..< 32:
    value.data[i] = data.get()[i]

## End of MessageDigest serde

## Beginning of HistoryCursorRest serde

proc writeValue*(
    writer: var JsonWriter, value: HistoryCursorRest
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("pubsubTopic", value.pubsubTopic)
  writer.writeField("senderTime", value.senderTime)
  writer.writeField("storeTime", value.storeTime)
  writer.writeField("digest", value.digest)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var HistoryCursorRest
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    pubsubTopic = none(PubsubTopic)
    senderTime = none(Timestamp)
    storeTime = none(Timestamp)
    digest = none(waku_store_common.MessageDigest)

  for fieldName in readObjectFields(reader):
    case fieldName
    of "pubsubTopic":
      if pubsubTopic.isSome():
        reader.raiseUnexpectedField(
          "Multiple `pubsubTopic` fields found", "HistoryCursorRest"
        )
      pubsubTopic = some(reader.readValue(PubsubTopic))
    of "senderTime":
      if senderTime.isSome():
        reader.raiseUnexpectedField(
          "Multiple `senderTime` fields found", "HistoryCursorRest"
        )
      senderTime = some(reader.readValue(Timestamp))
    of "storeTime":
      if storeTime.isSome():
        reader.raiseUnexpectedField(
          "Multiple `storeTime` fields found", "HistoryCursorRest"
        )
      storeTime = some(reader.readValue(Timestamp))
    of "digest":
      if digest.isSome():
        reader.raiseUnexpectedField(
          "Multiple `digest` fields found", "HistoryCursorRest"
        )
      digest = some(reader.readValue(waku_store_common.MessageDigest))
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if pubsubTopic.isNone():
    reader.raiseUnexpectedValue("Field `pubsubTopic` is missing")

  if senderTime.isNone():
    reader.raiseUnexpectedValue("Field `senderTime` is missing")

  if storeTime.isNone():
    reader.raiseUnexpectedValue("Field `storeTime` is missing")

  if digest.isNone():
    reader.raiseUnexpectedValue("Field `digest` is missing")

  value = HistoryCursorRest(
    pubsubTopic: pubsubTopic.get(),
    senderTime: senderTime.get(),
    storeTime: storeTime.get(),
    digest: digest.get(),
  )

## End of HistoryCursorRest serde

## Beginning of StoreResponseRest serde

proc writeValue*(
    writer: var JsonWriter, value: StoreResponseRest
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("messages", value.messages)
  if value.cursor.isSome():
    writer.writeField("cursor", value.cursor.get())
  if value.errorMessage.isSome():
    writer.writeField("errorMessage", value.errorMessage.get())
  writer.endRecord()

proc readValue*(
    reader: var JsonReader, value: var StoreResponseRest
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    messages = none(seq[StoreWakuMessage])
    cursor = none(HistoryCursorRest)
    errorMessage = none(string)

  for fieldName in readObjectFields(reader):
    case fieldName
    of "messages":
      if messages.isSome():
        reader.raiseUnexpectedField(
          "Multiple `messages` fields found", "StoreResponseRest"
        )
      messages = some(reader.readValue(seq[StoreWakuMessage]))
    of "cursor":
      if cursor.isSome():
        reader.raiseUnexpectedField(
          "Multiple `cursor` fields found", "StoreResponseRest"
        )
      cursor = some(reader.readValue(HistoryCursorRest))
    of "errorMessage":
      if errorMessage.isSome():
        reader.raiseUnexpectedField(
          "Multiple `errorMessage` fields found", "StoreResponseRest"
        )
      errorMessage = some(reader.readValue(string))
    else:
      reader.raiseUnexpectedField("Unrecognided field", cstring(fieldName))

  if messages.isNone():
    reader.raiseUnexpectedValue("Field `messages` is missing")

  value = StoreResponseRest(
    messages: messages.get(), cursor: cursor, errorMessage: errorMessage
  )

## End of StoreResponseRest serde

## Beginning of StoreRequestRest serde

proc writeValue*(
    writer: var JsonWriter, value: StoreRequestRest
) {.gcsafe, raises: [IOError].} =
  writer.beginRecord()
  if value.pubsubTopic.isSome():
    writer.writeField("pubsubTopic", value.pubsubTopic.get())
  writer.writeField("contentTopics", value.contentTopics)
  if value.startTime.isSome():
    writer.writeField("startTime", value.startTime.get())
  if value.endTime.isSome():
    writer.writeField("endTime", value.endTime.get())
  writer.writeField("pageSize", value.pageSize)
  writer.writeField("ascending", value.ascending)
  writer.endRecord()

## End of StoreRequestRest serde
