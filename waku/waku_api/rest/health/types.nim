{.push raises: [].}

import chronicles, json_serialization, json_serialization/std/options
import ../../../waku_node, ../serdes

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: ProtocolHealth
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField(value.protocol, $value.health)
  writer.writeField("desc", value.desc)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var ProtocolHealth
) {.gcsafe, raises: [SerializationError, IOError].} =
  var protocol = none[string]()
  var health = none[HealthStatus]()
  var desc = none[string]()
  for fieldName in readObjectFields(reader):
    if fieldName == "desc":
      if desc.isSome():
        reader.raiseUnexpectedField("Multiple `desc` fields found", "ProtocolHealth")
      desc = some(reader.readValue(string))
    else:
      if protocol.isSome():
        reader.raiseUnexpectedField(
          "Multiple `protocol` fields and value found", "ProtocolHealth"
        )

      let fieldValue = reader.readValue(string)
      try:
        health = some(HealthStatus.init(fieldValue))
        protocol = some(fieldName)
      except ValueError:
        reader.raiseUnexpectedValue("Invalid `health` value: " & getCurrentExceptionMsg())

    value = ProtocolHealth(protocol: protocol.get(), health: health.get(), desc: desc)

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
      unrecognizedFieldWarning(value)

  if nodeHealth.isNone():
    reader.raiseUnexpectedValue("Field `nodeHealth` is missing")

  value =
    HealthReport(nodeHealth: nodeHealth.get, protocolsHealth: protocolsHealth.get(@[]))
