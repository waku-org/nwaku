## Collection of utilities related to Waku's use of EIP-778 ENR
## Implemented according to the specified Waku v2 ENR usage
## More at https://rfc.vac.dev/spec/31/

{.push raises: [Defect]}

import
  std/[bitops, sequtils],
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/[multiaddress, multicodec],
  libp2p/crypto/crypto,
  stew/[endians2, results],
  stew/shims/net,
  std/bitops

export enr, crypto, multiaddress, net

const
  MULTIADDR_ENR_FIELD* = "multiaddrs"
  WAKU_ENR_FIELD* = "waku2"

type
  ## 8-bit flag field to indicate Waku capabilities.
  ## Only the 4 LSBs are currently defined according
  ## to RFC31 (https://rfc.vac.dev/spec/31/).
  WakuEnrBitfield* = uint8

  ## See: https://rfc.vac.dev/spec/31/#waku2-enr-key
  ## each enum numbers maps to a bit (where 0 is the LSB)
  Capabilities* = enum
    Relay = 0,
    Store = 1,
    Filter = 2,
    Lightpush = 3,

func toFieldPair(multiaddrs: seq[MultiAddress]): FieldPair =
  ## Converts a seq of multiaddrs to a `multiaddrs` ENR
  ## field pair according to https://rfc.vac.dev/spec/31/
  
  var fieldRaw: seq[byte]

  for multiaddr in multiaddrs:
    let
      maRaw = multiaddr.data.buffer # binary encoded multiaddr
      maSize = maRaw.len.uint16.toBytes(Endianness.bigEndian) # size as Big Endian unsigned 16-bit integer
    
    assert maSize.len == 2

    fieldRaw.add(concat(@maSize, maRaw))
  
  return toFieldPair(MULTIADDR_ENR_FIELD, fieldRaw)

func stripPeerId(multiaddr: MultiAddress): MultiAddress =
  var cleanAddr = MultiAddress.init()

  for item in multiaddr.items:
    if item[].protoName()[] != "p2p":
      # Add all parts except p2p peerId
      discard cleanAddr.append(item[])
  
  return cleanAddr

func stripPeerIds(multiaddrs: seq[MultiAddress]): seq[MultiAddress] =
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

################
# Public utils #
################

func initWakuFlags*(lightpush, filter, store, relay: bool): WakuEnrBitfield =
  ## Creates an waku2 ENR flag bit field according to RFC 31 (https://rfc.vac.dev/spec/31/)
  var v = 0b0000_0000'u8
  if lightpush: v.setBit(3)
  if filter: v.setBit(2)
  if store: v.setBit(1)
  if relay: v.setBit(0)

  # TODO: With the changes in this PR, this can be refactored? Using the enum?
  # Perhaps refactor to:
    # WaKuEnr.initEnr(..., capabilities=[Store, Lightpush])
    # WaKuEnr.initEnr(..., capabilities=[Store, Lightpush, Relay, Filter])

  # Safer also since we dont inject WakuEnrBitfield, and we let this package
  # handle the bits according to the capabilities

  return v.WakuEnrBitfield

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

func initEnr*(privateKey: crypto.PrivateKey,
              enrIp: Option[ValidIpAddress],
              enrTcpPort, enrUdpPort: Option[Port],
              wakuFlags = none(WakuEnrBitfield),
              multiaddrs: seq[MultiAddress] = @[]): enr.Record =
  
  assert privateKey.scheme == PKScheme.Secp256k1

  ## Waku-specific ENR fields (https://rfc.vac.dev/spec/31/)
  var wakuEnrFields: seq[FieldPair]

  # `waku2` field
  if wakuFlags.isSome:
    wakuEnrFields.add(toFieldPair(WAKU_ENR_FIELD, @[wakuFlags.get().byte]))

  # `multiaddrs` field
  if multiaddrs.len > 0:
    wakuEnrFields.add(multiaddrs.stripPeerIds().toFieldPair)

  let
    rawPk = privateKey.getRawBytes().expect("Private key is valid")
    pk = keys.PrivateKey.fromRaw(rawPk).expect("Raw private key is of valid length")
    enr = enr.Record.init(1, pk,
                          enrIp, enrTcpPort, enrUdpPort,
                          wakuEnrFields).expect("Record within size limits")
  
  return enr

proc supportsCapability*(r: Record, capability: Capabilities): bool = 
  let enrCapabilities = r.get(WAKU_ENR_FIELD, seq[byte])
  if enrCapabilities.isOk():
    return testBit(enrCapabilities.get()[0], capability.ord)
  return false

proc getCapabilities*(r: Record): seq[Capabilities] =
  return toSeq(Capabilities.low..Capabilities.high).filterIt(r.supportsCapability(it))