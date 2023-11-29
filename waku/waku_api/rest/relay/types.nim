when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets, strformat],
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import
  ../../../common/base64,
  ../../../waku_core,
  ../serdes


#### Types

type RelayWakuMessage* = object
      payload*: Base64String
      contentTopic*: Option[ContentTopic]
      version*: Option[Natural]
      timestamp*: Option[int64]


type
  RelayGetMessagesResponse* = seq[RelayWakuMessage]
  RelayPostMessagesRequest* = RelayWakuMessage

#### Type conversion

proc toRelayWakuMessage*(msg: WakuMessage): RelayWakuMessage =
  RelayWakuMessage(
    payload: base64.encode(msg.payload),
    contentTopic: some(msg.contentTopic),
    version: some(Natural(msg.version)),
    timestamp: some(msg.timestamp)
  )

proc toWakuMessage*(msg: RelayWakuMessage, version = 0): Result[WakuMessage, string] =
  let
    payload = ?msg.payload.decode()
    contentTopic = msg.contentTopic.get(DefaultContentTopic)
    version = uint32(msg.version.get(version))
    timestamp = msg.timestamp.get(0)

  if timestamp == 0:
    return err("timestamp cannot be 0 or empty")

  return ok(WakuMessage(payload: payload, contentTopic: contentTopic, version: version, timestamp: timestamp))


#### Serialization and deserialization

proc writeValue*(writer: var JsonWriter[RestJson], value: Base64String)
  {.raises: [IOError].} =
  writer.writeValue(string(value))

proc writeValue*(writer: var JsonWriter[RestJson], value: RelayWakuMessage)
  {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("payload", value.payload)
  if value.contentTopic.isSome:
    writer.writeField("contentTopic", value.contentTopic)
  if value.version.isSome:
    writer.writeField("version", value.version)
  if value.timestamp.isSome:
    writer.writeField("timestamp", value.timestamp)
  writer.endRecord()

proc readValue*(reader: var JsonReader[RestJson], value: var Base64String)
  {.raises: [SerializationError, IOError].} =
  value = Base64String(reader.readValue(string))

proc readValue*(reader: var JsonReader[RestJson], value: var RelayWakuMessage)
  {.raises: [SerializationError, IOError].} =
  var
    payload = none(Base64String)
    contentTopic = none(ContentTopic)
    version = none(Natural)
    timestamp = none(int64)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except CatchableError: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "RelayWakuMessage")

    case fieldName
    of "payload":
      payload = some(reader.readValue(Base64String))
    of "contentTopic":
      contentTopic = some(reader.readValue(ContentTopic))
    of "version":
      version = some(reader.readValue(Natural))
    of "timestamp":
      timestamp = some(reader.readValue(int64))
    else:
      unrecognizedFieldWarning()

  if payload.isNone() or isEmptyOrWhitespace(string(payload.get())):
    reader.raiseUnexpectedValue("Field `payload` is missing or empty")

  if contentTopic.isNone() or contentTopic.get().isEmptyOrWhitespace():
    reader.raiseUnexpectedValue("Field `contentTopic` is missing or empty")

  value = RelayWakuMessage(
    payload: payload.get(),
    contentTopic: contentTopic,
    version: version,
    timestamp: timestamp
  )
