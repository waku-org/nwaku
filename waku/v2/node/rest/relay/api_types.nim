{.push raises: [ Defect ].}

import
  std/[sets, strformat],
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import ".."/serdes
import ../../wakunode2


#### Types

type
    PubSubTopicString* = distinct string
    ContentTopicString* = distinct string

type RelayWakuMessage* = object
      payload*: string
      contentTopic*: Option[ContentTopicString]
      version*: Option[Natural]
      timestamp*: Option[int64]


type 
  RelayGetMessagesResponse* = seq[RelayWakuMessage]
  RelayPostMessagesRequest* = RelayWakuMessage

type
  RelayPostSubscriptionsRequest* = seq[PubSubTopicString]
  RelayDeleteSubscriptionsRequest* = seq[PubSubTopicString]


#### Type conversion

proc toRelayWakuMessage*(msg: WakuMessage): RelayWakuMessage =
  RelayWakuMessage(
    payload: string.fromBytes(msg.payload),
    contentTopic: some(ContentTopicString(msg.contentTopic)),
    version: some(Natural(msg.version)),
    timestamp: some(msg.timestamp)
  )

proc toWakuMessage*(msg: RelayWakuMessage, version = 0): WakuMessage =
  const defaultContentTopic = ContentTopicString("/waku/2/default-content/proto")
  WakuMessage(
    payload: msg.payload.toBytes(),
    contentTopic: ContentTopic(msg.contentTopic.get(defaultContentTopic)),
    version: uint32(msg.version.get(version)),
    timestamp: msg.timestamp.get(0)
  )

#### Serialization and deserialization

proc writeValue*(writer: var JsonWriter[RestJson], value: PubSubTopicString)
  {.raises: [IOError, Defect].} =
  writer.writeValue(string(value))
  
proc writeValue*(writer: var JsonWriter[RestJson], value: ContentTopicString)
  {.raises: [IOError, Defect].} =
  writer.writeValue(string(value))

proc writeValue*(writer: var JsonWriter[RestJson], value: RelayWakuMessage)
  {.raises: [IOError, Defect].} =
  writer.beginRecord()
  writer.writeField("payload", value.payload)
  if value.contentTopic.isSome:
    writer.writeField("contentTopic", value.contentTopic)
  if value.version.isSome:
    writer.writeField("version", value.version)
  if value.timestamp.isSome:
    writer.writeField("timestamp", value.timestamp)
  writer.endRecord()

proc readValue*(reader: var JsonReader[RestJson], value: var PubSubTopicString)
  {.raises: [SerializationError, IOError, Defect].} =
  value = PubSubTopicString(reader.readValue(string))

proc readValue*(reader: var JsonReader[RestJson], value: var ContentTopicString)
  {.raises: [SerializationError, IOError, Defect].} =
  value = ContentTopicString(reader.readValue(string))

proc readValue*(reader: var JsonReader[RestJson], value: var RelayWakuMessage)
  {.raises: [SerializationError, IOError, Defect].} =
  var
    payload = none(string)
    contentTopic = none(ContentTopicString)
    version = none(Natural)
    timestamp = none(int64)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "RelayWakuMessage")

    case fieldName
    of "payload":
      payload = some(reader.readValue(string))
    of "contentTopic":
      contentTopic = some(reader.readValue(ContentTopicString))
    of "version":
      version = some(reader.readValue(Natural))
    of "timestamp":
      timestamp = some(reader.readValue(int64))
    else:
      unrecognizedFieldWarning()

  if payload.isNone():
    reader.raiseUnexpectedValue("Field `payload` is missing")

  value = RelayWakuMessage(
    payload: payload.get(),
    contentTopic: contentTopic,
    version: version,
    timestamp: timestamp 
  )
