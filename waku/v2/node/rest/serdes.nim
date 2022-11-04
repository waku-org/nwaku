when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import 
  std/typetraits,
  stew/results,
  stew/byteutils,
  chronicles,
  serialization,
  json_serialization,
  json_serialization/std/options,
  json_serialization/std/net,
  json_serialization/std/sets,
  presto/common

logScope: 
  topics = "waku node rest"

Json.createFlavor RestJson

template unrecognizedFieldWarning* =
  # TODO: There should be a different notification mechanism for informing the
  #       caller of a deserialization routine for unexpected fields.
  #       The chonicles import in this module should be removed.
  debug "JSON field not recognized by the current version of nwaku. Consider upgrading",
        fieldName, typeName = typetraits.name(typeof value)


type SerdesResult*[T] = Result[T, cstring]

proc decodeFromJsonString*[T](t: typedesc[T],
                          data: JsonString,
                          requireAllFields = true): SerdesResult[T] =
  try:
    ok(RestJson.decode(string(data), T,
                       requireAllFields = requireAllFields,
                       allowUnknownFields = true))
  except SerializationError:
    # TODO: Do better error reporting here
    err("Unable to deserialize data")

proc decodeFromJsonBytes*[T](t: typedesc[T],
                         data: openArray[byte],
                         requireAllFields = true): SerdesResult[T] =
  try:
    ok(RestJson.decode(string.fromBytes(data), T,
                       requireAllFields = requireAllFields,
                       allowUnknownFields = true))
  except SerializationError:
    # TODO: Do better error reporting here
    err("Unable to deserialize data")

proc encodeIntoJsonString*(value: auto): SerdesResult[string] =
  var encoded: string
  try:
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.writeValue(value)
    encoded = stream.getOutput(string)
  except SerializationError, IOError:
    # TODO: Do better error reporting here
    return err("unable to serialize data")

  ok(encoded)

proc encodeIntoJsonBytes*(value: auto): SerdesResult[seq[byte]] =
  var encoded: seq[byte]
  try:
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.writeValue(value)
    encoded = stream.getOutput(seq[byte])
  except SerializationError, IOError:
    # TODO: Do better error reporting here
    return err("unable to serialize data")

  ok(encoded)


#### helpers

proc encodeString*(value: string): RestResult[string] =
  ok(value)

proc decodeString*(t: typedesc[string], value: string): RestResult[string] =
  ok(value)
