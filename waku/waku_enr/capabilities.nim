{.push raises: [].}

import
  std/[options, bitops, sequtils, net, tables], results, eth/keys, libp2p/crypto/crypto
import ../common/enr, ../waku_core/codecs

const CapabilitiesEnrField* = "waku2"

type
  ## 8-bit flag field to indicate Waku node capabilities.
  ## Only the 4 LSBs are currently defined according
  ## to RFC31 (https://rfc.vac.dev/spec/31/).
  CapabilitiesBitfield* = distinct uint8

  ## See: https://rfc.vac.dev/spec/31/#waku2-enr-key
  ## each enum numbers maps to a bit (where 0 is the LSB)
  Capabilities* {.pure.} = enum
    Relay = 0
    Store = 1
    Filter = 2
    Lightpush = 3
    Sync = 4

const capabilityToCodec = {
  Capabilities.Relay: WakuRelayCodec,
  Capabilities.Store: WakuStoreCodec,
  Capabilities.Filter: WakuFilterSubscribeCodec,
  Capabilities.Lightpush: WakuLightPushCodec,
  Capabilities.Sync: WakuReconciliationCodec,
}.toTable

func init*(
    T: type CapabilitiesBitfield, lightpush, filter, store, relay, sync: bool = false
): T =
  ## Creates an waku2 ENR flag bit field according to RFC 31 (https://rfc.vac.dev/spec/31/)
  var bitfield: uint8
  if relay:
    bitfield.setBit(0)
  if store:
    bitfield.setBit(1)
  if filter:
    bitfield.setBit(2)
  if lightpush:
    bitfield.setBit(3)
  if sync:
    bitfield.setBit(4)
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
  toSeq(Capabilities.low .. Capabilities.high).filterIt(
    supportsCapability(bitfield, it)
  )

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

  if field.get().len != 1:
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

proc getCapabilitiesCodecs*(r: Record): seq[string] {.raises: [ValueError].} =
  let capabilities = r.getCapabilities()
  return capabilities.mapIt(capabilityToCodec[it])
