when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets, strformat],
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common],
  libp2p/peerid
import
  ../../../common/base64,
  ../../../waku_core,
  ../serdes

#### Types

type FilterWakuMessage* = object
      payload*: Base64String
      contentTopic*: Option[ContentTopic]
      version*: Option[Natural]
      timestamp*: Option[int64]

type FilterGetMessagesResponse* = seq[FilterWakuMessage]

type FilterLegacySubscribeRequest* = object
      # Subscription request for legacy filter support
      pubsubTopic*: Option[PubSubTopic]
      contentFilters*: seq[ContentTopic]

type FilterSubscriberPing* = object
      requestId*: string

type FilterSubscribeRequest* = object
      requestId*: string
      pubsubTopic*: Option[PubSubTopic]
      contentFilters*: seq[ContentTopic]

type FilterUnsubscribeRequest* = object
      requestId*: string
      pubsubTopic*: Option[PubSubTopic]
      contentFilters*: seq[ContentTopic]

type FilterUnsubscribeAllRequest* = object
      requestId*: string

type FilterSubscriptionResponse* = object
      requestId*: string
      statusCode*: uint32
      statusDesc*: string

#### Type conversion

proc toFilterWakuMessage*(msg: WakuMessage): FilterWakuMessage =
  FilterWakuMessage(
    payload: base64.encode(msg.payload),
    contentTopic: some(msg.contentTopic),
    version: some(Natural(msg.version)),
    timestamp: some(msg.timestamp)
  )

proc toWakuMessage*(msg: FilterWakuMessage, version = 0): Result[WakuMessage, string] =
  let
    payload = ?msg.payload.decode()
    contentTopic = msg.contentTopic.get(DefaultContentTopic)
    version = uint32(msg.version.get(version))
    timestamp = msg.timestamp.get(0)

  ok(WakuMessage(payload: payload, contentTopic: contentTopic, version: version, timestamp: timestamp))

#### Serialization and deserialization

proc writeValue*(writer: var JsonWriter[RestJson], value: Base64String)
  {.raises: [IOError].} =
  writer.writeValue(string(value))

proc writeValue*(writer: var JsonWriter[RestJson], value: FilterWakuMessage)
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

proc writeValue*(writer: var JsonWriter[RestJson], value: FilterLegacySubscribeRequest)
  {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("pubsubTopic", value.pubsubTopic)
  writer.writeField("contentFilters", value.contentFilters)
  writer.endRecord()

proc readValue*(reader: var JsonReader[RestJson], value: var Base64String)
  {.raises: [SerializationError, IOError].} =
  value = Base64String(reader.readValue(string))

proc readValue*(reader: var JsonReader[RestJson], value: var FilterWakuMessage)
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
      reader.raiseUnexpectedField(err, "FilterWakuMessage")

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

  if payload.isNone():
    reader.raiseUnexpectedValue("Field `payload` is missing")

  value = FilterWakuMessage(
    payload: payload.get(),
    contentTopic: contentTopic,
    version: version,
    timestamp: timestamp
  )

proc readValue*(reader: var JsonReader[RestJson], value: var FilterLegacySubscribeRequest)
  {.raises: [SerializationError, IOError].} =
  var
    pubsubTopic = none(PubsubTopic)
    contentFilters = none(seq[ContentTopic])

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except CatchableError: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterLegacySubscribeRequest")

    case fieldName
    of "pubsubTopic":
      pubsubTopic = some(reader.readValue(PubsubTopic))
    of "contentFilters":
      contentFilters = some(reader.readValue(seq[ContentTopic]))
    else:
      unrecognizedFieldWarning()

  if contentFilters.isNone():
    reader.raiseUnexpectedValue("Field `contentFilters` is missing")

  if contentFilters.get().len() == 0:
    reader.raiseUnexpectedValue("Field `contentFilters` is empty")

  value = FilterLegacySubscribeRequest(
    pubsubTopic: if pubsubTopic.isNone() or pubsubTopic.get() == "": none(string) else: some(pubsubTopic.get()),
    contentFilters: contentFilters.get()
  )

proc readValue*(reader: var JsonReader[RestJson], value: var FilterSubscriberPing)
  {.raises: [SerializationError, IOError].} =
  var
    requestId = none(string)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except CatchableError: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterSubscriberPing")

    case fieldName
    of "requestId":
      requestId = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning()

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  value = FilterSubscriberPing(
    requestId: requestId.get()
  )

proc readValue*(reader: var JsonReader[RestJson], value: var FilterSubscribeRequest)
  {.raises: [SerializationError, IOError].} =
  var
    requestId = none(string)
    pubsubTopic = none(PubsubTopic)
    contentFilters = none(seq[ContentTopic])

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except CatchableError: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterSubscribeRequest")

    case fieldName
    of "requestId":
      requestId = some(reader.readValue(string))
    of "pubsubTopic":
      pubsubTopic = some(reader.readValue(PubsubTopic))
    of "contentFilters":
      contentFilters = some(reader.readValue(seq[ContentTopic]))
    else:
      unrecognizedFieldWarning()

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  if contentFilters.isNone():
    reader.raiseUnexpectedValue("Field `contentFilters` is missing")

  if contentFilters.get().len() == 0:
    reader.raiseUnexpectedValue("Field `contentFilters` is empty")

  value = FilterSubscribeRequest(
    requestId: requestId.get(),
    pubsubTopic: if pubsubTopic.isNone() or pubsubTopic.get() == "": none(string) else: some(pubsubTopic.get()),
    contentFilters: contentFilters.get()
  )

proc readValue*(reader: var JsonReader[RestJson], value: var FilterUnsubscribeRequest)
  {.raises: [SerializationError, IOError].} =
  var
    requestId = none(string)
    pubsubTopic = none(PubsubTopic)
    contentFilters = none(seq[ContentTopic])

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except CatchableError: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterUnsubscribeRequest")

    case fieldName
    of "requestId":
      requestId = some(reader.readValue(string))
    of "pubsubTopic":
      pubsubTopic = some(reader.readValue(PubsubTopic))
    of "contentFilters":
      contentFilters = some(reader.readValue(seq[ContentTopic]))
    else:
      unrecognizedFieldWarning()

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  if contentFilters.isNone():
    reader.raiseUnexpectedValue("Field `contentFilters` is missing")

  if contentFilters.get().len() == 0:
    reader.raiseUnexpectedValue("Field `contentFilters` is empty")

  value = FilterUnsubscribeRequest(
    requestId: requestId.get(),
    pubsubTopic: if pubsubTopic.isNone() or pubsubTopic.get() == "": none(string) else: some(pubsubTopic.get()),
    contentFilters: contentFilters.get()
  )

proc readValue*(reader: var JsonReader[RestJson], value: var FilterUnsubscribeAllRequest)
  {.raises: [SerializationError, IOError].} =
  var
    requestId = none(string)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except CatchableError: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterUnsubscribeAllRequest")

    case fieldName
    of "requestId":
      requestId = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning()

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  value = FilterUnsubscribeAllRequest(
    requestId: requestId.get(),
  )

proc readValue*(reader: var JsonReader[RestJson], value: var FilterSubscriptionResponse)
  {.raises: [SerializationError, IOError].} =
  var
    requestId = none(string)
    statusCode = none(uint32)
    statusDesc = none(string)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err = try: fmt"Multiple `{fieldName}` fields found"
                except CatchableError: "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterSubscriptionResponse")

    case fieldName
    of "requestId":
      requestId = some(reader.readValue(string))
    of "statusCode":
      statusCode = some(reader.readValue(uint32))
    of "statusDesc":
      statusDesc = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning()

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  value = FilterSubscriptionResponse(
    requestId: requestId.get(),
    statusCode: statusCode.get(),
    statusDesc: statusDesc.get("")
  )
