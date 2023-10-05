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
  ProtocolState* = object
    protocol*: string
    connected*: bool

type
  WakuPeer* = object
    multiaddr*: string
    protocols*: seq[ProtocolState]

type WakuPeers* = seq[WakuPeer]

#### Serialization and deserialization

proc writeValue*(writer: var JsonWriter[RestJson], value: ProtocolState)
  {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("protocol", value.protocol)
  writer.writeField("connected", value.connected)
  writer.endRecord()

proc writeValue*(writer: var JsonWriter[RestJson], value: WakuPeer)
  {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("multiaddr", value.multiaddr)
  writer.writeField("protocols", value.protocols)
  writer.endRecord()

proc readValue*(reader: var JsonReader[RestJson], value: var ProtocolState)
  {.gcsafe, raises: [SerializationError, IOError].} =
  var
    protocol: Option[string]
    connected: Option[bool]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "protocol":
      if protocol.isSome():
        reader.raiseUnexpectedField("Multiple `protocol` fields found", "ProtocolState")
      protocol = some(reader.readValue(string))
    of "connected":
      if connected.isSome():
        reader.raiseUnexpectedField("Multiple `connected` fields found", "ProtocolState")
      connected = some(reader.readValue(bool))
    else:
      unrecognizedFieldWarning()

  if connected.isNone():
    reader.raiseUnexpectedValue("Field `connected` is missing")

  if protocol.isNone():
    reader.raiseUnexpectedValue("Field `protocol` is missing")

  value = ProtocolState(
      protocol: protocol.get(),
      connected: connected.get()
    )

proc readValue*(reader: var JsonReader[RestJson], value: var WakuPeer)
  {.gcsafe, raises: [SerializationError, IOError].} =
  var
    multiaddr: Option[string]
    protocols: Option[seq[ProtocolState]]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "multiaddr":
      if multiaddr.isSome():
        reader.raiseUnexpectedField("Multiple `multiaddr` fields found", "WakuPeer")
      multiaddr = some(reader.readValue(string))
    of "protocols":
      if protocols.isSome():
        reader.raiseUnexpectedField("Multiple `protocols` fields found", "WakuPeer")
      protocols = some(reader.readValue(seq[ProtocolState]))
    else:
      unrecognizedFieldWarning()

  if multiaddr.isNone():
    reader.raiseUnexpectedValue("Field `multiaddr` is missing")

  if protocols.isNone():
    reader.raiseUnexpectedValue("Field `protocols` are missing")

  value = WakuPeer(
      multiaddr: multiaddr.get(),
      protocols: protocols.get()
    )

## Utility for populating WakuPeers and ProtocolState
func `==`*(a, b: ProtocolState): bool {.inline.} =
  return a.protocol == b.protocol

func `==`*(a: ProtocolState, b: string): bool {.inline.} =
  return a.protocol == b

func `==`*(a, b: WakuPeer): bool {.inline.} =
  return a.multiaddr == b.multiaddr

proc add*(peers: var WakuPeers, multiaddr: string, protocol: string, connected: bool) =
  var
    peer: WakuPeer = WakuPeer(
            multiaddr: multiaddr,
            protocols: @[ProtocolState(
                          protocol: protocol,
                          connected: connected
                        )]
          )
  let idx = peers.find(peer)

  if idx < 0:
    peers.add(peer)
  else:
    peers[idx].protocols.add(ProtocolState(
                          protocol: protocol,
                          connected: connected
                        ))

