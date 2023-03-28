## Collection of utilities related to Waku's use of EIP-778 ENR
## Implemented according to the specified Waku v2 ENR usage
## More at https://rfc.vac.dev/spec/31/

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, bitops, sequtils],
  stew/[endians2, results],
  stew/shims/net,
  eth/keys,
  libp2p/[multiaddress, multicodec],
  libp2p/crypto/crypto
import
  ../../common/enr

export enr, crypto, multiaddress, net

const
  MultiaddrEnrField* = "multiaddrs"
  CapabilitiesEnrField* = "waku2"


## Node capabilities

type
  ## 8-bit flag field to indicate Waku node capabilities.
  ## Only the 4 LSBs are currently defined according
  ## to RFC31 (https://rfc.vac.dev/spec/31/).
  CapabilitiesBitfield* = distinct uint8

  ## See: https://rfc.vac.dev/spec/31/#waku2-enr-key
  ## each enum numbers maps to a bit (where 0 is the LSB)
  Capabilities*{.pure.} = enum
    Relay = 0,
    Store = 1,
    Filter = 2,
    Lightpush = 3


func init*(T: type CapabilitiesBitfield, lightpush, filter, store, relay: bool): T =
  ## Creates an waku2 ENR flag bit field according to RFC 31 (https://rfc.vac.dev/spec/31/)
  var bitfield: uint8
  if relay: bitfield.setBit(0)
  if store: bitfield.setBit(1)
  if filter: bitfield.setBit(2)
  if lightpush: bitfield.setBit(3)
  CapabilitiesBitfield(bitfield)

func init*(T: type CapabilitiesBitfield, caps: varargs[Capabilities]): T =
  ## Creates an waku2 ENR flag bit field according to RFC 31 (https://rfc.vac.dev/spec/31/)
  var bitfield: uint8
  for cap in caps:
    bitfield.setBit(ord(cap))
  CapabilitiesBitfield(bitfield)

converter toCapabilitiesBitfield*(field: uint8): CapabilitiesBitfield =
  CapabilitiesBitfield(field)

proc supportsCapability*(bitfield: CapabilitiesBitfield, cap: Capabilities): bool =
  testBit(bitfield.uint8, ord(cap))

func toCapabilities*(bitfield: CapabilitiesBitfield): seq[Capabilities] =
  toSeq(Capabilities.low..Capabilities.high).filterIt(supportsCapability(bitfield, it))


# ENR builder extension

proc withWakuCapabilities*(builder: var EnrBuilder, caps: CapabilitiesBitfield) =
  builder.addFieldPair(CapabilitiesEnrField, @[caps.uint8])

proc withWakuCapabilities*(builder: var EnrBuilder, caps: varargs[Capabilities]) =
  withWakuCapabilities(builder, CapabilitiesBitfield.init(caps))

proc withWakuCapabilities*(builder: var EnrBuilder, caps: openArray[Capabilities]) =
  withWakuCapabilities(builder, CapabilitiesBitfield.init(@caps))


# ENR record accessors (e.g., Record, TypedRecord, etc.)

func waku2*(record: TypedRecord): Option[CapabilitiesBitfield] =
  let field = record.tryGet(CapabilitiesEnrField, seq[uint8])
  if field.isNone():
    return none(CapabilitiesBitfield)

  some(CapabilitiesBitfield(field.get()[0]))

proc supportsCapability*(r: Record, cap: Capabilities): bool =
  let recordRes = r.toTyped()
  if recordRes.isErr():
    return false

  let bitfieldOpt = recordRes.value.waku2
  if bitfieldOpt.isNone():
    return false

  let bitfield = bitfieldOpt.get()
  bitfield.supportsCapability(cap)

proc getCapabilities*(r: Record): seq[Capabilities] =
  let recordRes = r.toTyped()
  if recordRes.isErr():
    return @[]

  let bitfieldOpt = recordRes.value.waku2
  if bitfieldOpt.isNone():
    return @[]

  let bitfield = bitfieldOpt.get()
  bitfield.toCapabilities()


## Multiaddress

func encodeMultiaddrs*(multiaddrs: seq[MultiAddress]): seq[byte] =
  var buffer = newSeq[byte]()
  for multiaddr in multiaddrs:

    let
      raw = multiaddr.data.buffer # binary encoded multiaddr
      size = raw.len.uint16.toBytes(Endianness.bigEndian) # size as Big Endian unsigned 16-bit integer

    buffer.add(concat(@size, raw))

  buffer

func readBytes(rawBytes: seq[byte], numBytes: int, pos: var int = 0): Result[seq[byte], cstring] =
  ## Attempts to read `numBytes` from a sequence, from
  ## position `pos`. Returns the requested slice or
  ## an error if `rawBytes` boundary is exceeded.
  ##
  ## If successful, `pos` is advanced by `numBytes`
  if rawBytes[pos..^1].len() < numBytes:
    return err("insufficient bytes")

  let slicedSeq = rawBytes[pos..<pos+numBytes]
  pos += numBytes

  return ok(slicedSeq)

func decodeMultiaddrs(buffer: seq[byte]): EnrResult[seq[MultiAddress]] =
  ## Parses a `multiaddrs` ENR field according to
  ## https://rfc.vac.dev/spec/31/
  var multiaddrs: seq[MultiAddress]

  var pos = 0
  while pos < buffer.len():
    let addrLenRaw = ? readBytes(buffer, 2, pos)
    let addrLen = uint16.fromBytesBE(addrLenRaw)
    if addrLen == 0:
      # Ensure pos always advances and we don't get stuck in infinite loop
      return err("malformed multiaddr field: invalid length")

    let addrRaw = ? readBytes(buffer, addrLen.int, pos)
    let address = MultiAddress.init(addrRaw).get()

    multiaddrs.add(address)

  return ok(multiaddrs)


# ENR builder extension
func stripPeerId(multiaddr: MultiAddress): MultiAddress =
  if not multiaddr.contains(multiCodec("p2p")).get():
    return multiaddr

  var cleanAddr = MultiAddress.init()
  for item in multiaddr.items:
    if item.value.protoName().get() != "p2p":
      # Add all parts except p2p peerId
      discard cleanAddr.append(item.value)

  return cleanAddr

func withMultiaddrs*(builder: var EnrBuilder, multiaddrs: seq[MultiAddress]) =
  let multiaddrs = multiaddrs.map(stripPeerId)
  let value = encodeMultiaddrs(multiaddrs)
  builder.addFieldPair(MultiaddrEnrField, value)

func withMultiaddrs*(builder: var EnrBuilder, multiaddrs: varargs[MultiAddress]) =
  withMultiaddrs(builder, @multiaddrs)

# ENR record accessors (e.g., Record, TypedRecord, etc.)

func multiaddrs*(record: TypedRecord): Option[seq[MultiAddress]] =
  let field = record.tryGet(MultiaddrEnrField, seq[byte])
  if field.isNone():
    return none(seq[MultiAddress])

  let decodeRes = decodeMultiaddrs(field.get())
  if decodeRes.isErr():
    return none(seq[MultiAddress])

  some(decodeRes.value)

## Utils



## ENR

func init*(T: type enr.Record,
           seqNum: uint64,
           privateKey: crypto.PrivateKey,
           enrIp = none(ValidIpAddress),
           enrTcpPort = none(Port),
           enrUdpPort = none(Port),
           wakuFlags = none(CapabilitiesBitfield),
           multiaddrs: seq[MultiAddress] = @[]): T {.
  deprecated: "Use Waku commons EnrBuilder instead" .} =

  assert privateKey.scheme == PKScheme.Secp256k1

  ## Waku-specific ENR fields (https://rfc.vac.dev/spec/31/)
  var wakuEnrFields: seq[FieldPair]

  # `waku2` field
  if wakuFlags.isSome():
    wakuEnrFields.add(toFieldPair(CapabilitiesEnrField, @[wakuFlags.get().uint8]))

  # `multiaddrs` field
  if multiaddrs.len > 0:
    let value = encodeMultiaddrs(multiaddrs)
    wakuEnrFields.add(toFieldPair(MultiaddrEnrField, value))

  let
    rawPk = privateKey.getRawBytes().expect("Private key is valid")
    pk = keys.PrivateKey.fromRaw(rawPk).expect("Raw private key is of valid length")

  enr.Record.init(
    seqNum=seqNum,
    pk=pk,
    ip=enrIp,
    tcpPort=enrTcpPort,
    udpPort=enrUdpPort,
    extraFields=wakuEnrFields
  ).expect("Record within size limits")
