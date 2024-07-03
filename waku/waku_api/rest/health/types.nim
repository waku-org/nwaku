{.push raises: [].}

import chronicles, json_serialization, json_serialization/std/options
import ../../../waku_node, ../serdes

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: ProtocolHealth
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField(value.protocol, $value.health)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var ProtocolHealth
) {.gcsafe, raises: [SerializationError, IOError].} =
  var health: HealthStatus
  var fieldCount = 0

  for fieldName in readObjectFields(reader):
    if fieldCount > 0:
      reader.raiseUnexpectedField("Too many fields", "ProtocolHealth")
    fieldCount += 1

    let fieldValue = reader.readValue(string)
    try:
      health = HealthStatus.init(fieldValue)
    except ValueError:
      reader.raiseUnexpectedValue("Invalid `health` value")

    value = ProtocolHealth(protocol: fieldName, health: health)

proc writeValue*(
    writer: var JsonWriter[RestJson], value: HealthReport
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("nodeHealth", $value.nodeHealth)
  writer.writeField("protocolsHealth", value.protocolsHealth)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var HealthReport
) {.raises: [SerializationError, IOError].} =
  var
    nodeHealth: Option[HealthStatus]
    protocolsHealth: Option[seq[ProtocolHealth]]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "nodeHealth":
      if nodeHealth.isSome():
        reader.raiseUnexpectedField(
          "Multiple `nodeHealth` fields found", "HealthReport"
        )
      try:
        nodeHealth = some(HealthStatus.init(reader.readValue(string)))
      except ValueError:
        reader.raiseUnexpectedValue("Invalid `health` value")
    of "protocolsHealth":
      if protocolsHealth.isSome():
        reader.raiseUnexpectedField(
          "Multiple `protocolsHealth` fields found", "HealthReport"
        )

      protocolsHealth = some(reader.readValue(seq[ProtocolHealth]))
    else:
      unrecognizedFieldWarning()

  if nodeHealth.isNone():
    reader.raiseUnexpectedValue("Field `nodeHealth` is missing")

  value =
    HealthReport(nodeHealth: nodeHealth.get, protocolsHealth: protocolsHealth.get(@[]))
