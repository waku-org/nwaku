when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  json_serialization/lexer
import
  ../serdes

#### Types

type
  WakuPeer* = object
    multiaddr*: string
    protocol*: string
    connected*: bool

type WakuPeers* = seq[WakuPeer]

#### Serialization and deserialization

proc writeValue*(writer: var JsonWriter[RestJson], value: WakuPeer)
  {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("multiaddr", value.multiaddr)
  writer.writeField("protocol", value.protocol)
  writer.writeField("connected", value.connected)
  writer.endRecord()

proc readValue*(reader: var JsonReader[RestJson], value: var WakuPeer)
  {.gcsafe, raises: [SerializationError, IOError].} =
  var
    multiaddr: Option[string]
    protocol: Option[string]
    connected: Option[bool]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "multiaddr":
      if multiaddr.isSome():
        reader.raiseUnexpectedField("Multiple `multiaddr` fields found", "WakuPeer")
      multiaddr = some(reader.readValue(string))
    of "protocol":
      if protocol.isSome():
        reader.raiseUnexpectedField("Multiple `protocol` fields found", "WakuPeer")
      protocol = some(reader.readValue(string))
    of "connected":
      if connected.isSome():
        reader.raiseUnexpectedField("Multiple `connected` fields found", "WakuPeer")
      connected = some(reader.readValue(bool))
    else:
      unrecognizedFieldWarning()

  if multiaddr.isNone():
    reader.raiseUnexpectedValue("Field `multiaddr` is missing")

  if protocol.isNone():
    reader.raiseUnexpectedValue("Field `protocol` is missing")

  if connected.isNone():
    reader.raiseUnexpectedValue("Field `connected` is missing")

  value = WakuPeer(
      multiaddr: multiaddr.get(),
      protocol: protocol.get(),
      connected: connected.get()
    )
