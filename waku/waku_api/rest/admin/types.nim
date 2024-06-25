when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  json_serialization/lexer
import ../serdes, ../../../waku_core

#### Types

type ProtocolState* = object
  protocol*: string
  connected*: bool

type WakuPeer* = object
  multiaddr*: string
  protocols*: seq[ProtocolState]
  origin*: PeerOrigin

type WakuPeers* = seq[WakuPeer]

type FilterTopic* = object
  pubsubTopic*: string
  contentTopic*: string

type FilterSubscription* = object
  peerId*: string
  filterCriteria*: seq[FilterTopic]

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: ProtocolState
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("protocol", value.protocol)
  writer.writeField("connected", value.connected)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: WakuPeer
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("multiaddr", value.multiaddr)
  writer.writeField("protocols", value.protocols)
  writer.writeField("origin", value.origin)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterTopic
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("pubsubTopic", value.pubsubTopic)
  writer.writeField("contentTopic", value.contentTopic)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterSubscription
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("peerId", value.peerId)
  writer.writeField("filterCriteria", value.filterCriteria)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var ProtocolState
) {.gcsafe, raises: [SerializationError, IOError].} =
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
        reader.raiseUnexpectedField(
          "Multiple `connected` fields found", "ProtocolState"
        )
      connected = some(reader.readValue(bool))
    else:
      unrecognizedFieldWarning()

  if connected.isNone():
    reader.raiseUnexpectedValue("Field `connected` is missing")

  if protocol.isNone():
    reader.raiseUnexpectedValue("Field `protocol` is missing")

  value = ProtocolState(protocol: protocol.get(), connected: connected.get())

proc readValue*(
    reader: var JsonReader[RestJson], value: var WakuPeer
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    multiaddr: Option[string]
    protocols: Option[seq[ProtocolState]]
    origin: Option[PeerOrigin]

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
    of "origin":
      if origin.isSome():
        reader.raiseUnexpectedField("Multiple `origin` fields found", "WakuPeer")
      origin = some(reader.readValue(PeerOrigin))
    else:
      unrecognizedFieldWarning()

  if multiaddr.isNone():
    reader.raiseUnexpectedValue("Field `multiaddr` is missing")

  if protocols.isNone():
    reader.raiseUnexpectedValue("Field `protocols` are missing")

  if origin.isNone():
    reader.raiseUnexpectedValue("Field `origin` is missing")

  value = WakuPeer(
    multiaddr: multiaddr.get(), protocols: protocols.get(), origin: origin.get()
  )

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterTopic
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    pubsubTopic: Option[string]
    contentTopic: Option[string]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "pubsubTopic":
      if pubsubTopic.isSome():
        reader.raiseUnexpectedField(
          "Multiple `pubsubTopic` fields found", "FilterTopic"
        )
      pubsubTopic = some(reader.readValue(string))
    of "contentTopic":
      if contentTopic.isSome():
        reader.raiseUnexpectedField(
          "Multiple `contentTopic` fields found", "FilterTopic"
        )
      contentTopic = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning()

  if pubsubTopic.isNone():
    reader.raiseUnexpectedValue("Field `pubsubTopic` is missing")

  if contentTopic.isNone():
    reader.raiseUnexpectedValue("Field `contentTopic` are missing")

  value = FilterTopic(pubsubTopic: pubsubTopic.get(), contentTopic: contentTopic.get())

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterSubscription
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    peerId: Option[string]
    filterCriteria: Option[seq[FilterTopic]]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "peerId":
      if peerId.isSome():
        reader.raiseUnexpectedField(
          "Multiple `peerId` fields found", "FilterSubscription"
        )
      peerId = some(reader.readValue(string))
    of "filterCriteria":
      if filterCriteria.isSome():
        reader.raiseUnexpectedField(
          "Multiple `filterCriteria` fields found", "FilterSubscription"
        )
      filterCriteria = some(reader.readValue(seq[FilterTopic]))
    else:
      unrecognizedFieldWarning()

  if peerId.isNone():
    reader.raiseUnexpectedValue("Field `peerId` is missing")

  if filterCriteria.isNone():
    reader.raiseUnexpectedValue("Field `filterCriteria` are missing")

  value = FilterSubscription(peerId: peerId.get(), filterCriteria: filterCriteria.get())

## Utility for populating WakuPeers and ProtocolState
func `==`*(a, b: ProtocolState): bool {.inline.} =
  return a.protocol == b.protocol

func `==`*(a: ProtocolState, b: string): bool {.inline.} =
  return a.protocol == b

func `==`*(a, b: WakuPeer): bool {.inline.} =
  return a.multiaddr == b.multiaddr

proc add*(
    peers: var WakuPeers,
    multiaddr: string,
    protocol: string,
    connected: bool,
    origin: PeerOrigin,
) =
  var peer: WakuPeer = WakuPeer(
    multiaddr: multiaddr,
    protocols: @[ProtocolState(protocol: protocol, connected: connected)],
    origin: origin,
  )
  let idx = peers.find(peer)

  if idx < 0:
    peers.add(peer)
  else:
    peers[idx].protocols.add(ProtocolState(protocol: protocol, connected: connected))
