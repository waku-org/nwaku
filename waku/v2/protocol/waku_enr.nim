## Collection of utilities related to Waku's use of EIP-778 ENR
## Implemented according to the specified Waku v2 ENR usage
## More at https://rfc.vac.dev/spec/31/

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[bitops, sequtils],
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
  # TODO: Make this enum {.pure.}
  Capabilities* = enum
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

proc getCapabilitiesField*(r: Record): EnrResult[CapabilitiesBitfield] =
  let field = ?r.get(CapabilitiesEnrField, seq[uint8])
  ok(CapabilitiesBitfield(field[0]))


proc supportsCapability*(r: Record, cap: Capabilities): bool =
  let bitfield = getCapabilitiesField(r)
  if bitfield.isErr():
    return false

  bitfield.value.supportsCapability(cap)

proc getCapabilities*(r: Record): seq[Capabilities] =
  let bitfield = getCapabilitiesField(r)
  if bitfield.isErr():
    return @[]

  bitfield.value.toCapabilities()


## Multiaddress

func getRawField*(multiaddrs: seq[MultiAddress]): seq[byte] =
  var fieldRaw: seq[byte]

  for multiaddr in multiaddrs:
    let
      maRaw = multiaddr.data.buffer # binary encoded multiaddr
      maSize = maRaw.len.uint16.toBytes(Endianness.bigEndian) # size as Big Endian unsigned 16-bit integer

    assert maSize.len == 2

    fieldRaw.add(concat(@maSize, maRaw))

  return fieldRaw

func toFieldPair*(multiaddrs: seq[MultiAddress]): FieldPair =
  ## Converts a seq of multiaddrs to a `multiaddrs` ENR
  ## field pair according to https://rfc.vac.dev/spec/31/
  let fieldRaw = multiaddrs.getRawField()

  return toFieldPair(MULTIADDR_ENR_FIELD, fieldRaw)

func stripPeerId(multiaddr: MultiAddress): MultiAddress =
  var cleanAddr = MultiAddress.init()

  for item in multiaddr.items:
    if item[].protoName()[] != "p2p":
      # Add all parts except p2p peerId
      discard cleanAddr.append(item[])

  return cleanAddr

func stripPeerIds*(multiaddrs: seq[MultiAddress]): seq[MultiAddress] =
  var cleanAddrs: seq[MultiAddress]

  for multiaddr in multiaddrs:
    if multiaddr.contains(multiCodec("p2p"))[]:
      cleanAddrs.add(multiaddr.stripPeerId())
    else:
      cleanAddrs.add(multiaddr)

  return cleanAddrs

func readBytes(rawBytes: seq[byte], numBytes: int, pos: var int = 0): Result[seq[byte], cstring] =
  ## Attempts to read `numBytes` from a sequence, from
  ## position `pos`. Returns the requested slice or
  ## an error if `rawBytes` boundary is exceeded.
  ##
  ## If successful, `pos` is advanced by `numBytes`

  if rawBytes[pos..^1].len() < numBytes:
    return err("Exceeds maximum available bytes")

  let slicedSeq = rawBytes[pos..<pos+numBytes]
  pos += numBytes

  return ok(slicedSeq)

func toMultiAddresses*(multiaddrsField: seq[byte]): seq[MultiAddress] =
  ## Parses a `multiaddrs` ENR field according to
  ## https://rfc.vac.dev/spec/31/
  var multiaddrs: seq[MultiAddress]

  let totalLen = multiaddrsField.len()
  if totalLen < 2:
    return multiaddrs

  var pos = 0
  while pos < totalLen:
    let addrLenRes = multiaddrsField.readBytes(2, pos)
    if addrLenRes.isErr():
      return multiaddrs

    let addrLen = uint16.fromBytesBE(addrLenRes.get())
    if addrLen == 0.uint16:
      # Ensure pos always advances and we don't get stuck in infinite loop
      return multiaddrs

    let addrRaw = multiaddrsField.readBytes(addrLen.int, pos)
    if addrRaw.isErr():
      return multiaddrs

    let multiaddr = MultiAddress.init(addrRaw.get())
    if multiaddr.isErr():
      return multiaddrs

    multiaddrs.add(multiaddr.get())

  return multiaddrs


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
    wakuEnrFields.add(multiaddrs.stripPeerIds().toFieldPair())

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
