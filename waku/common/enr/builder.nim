{.push raises: [].}

import
  std/[options, net],
  results,
  eth/keys as eth_keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto as libp2p_crypto

## Builder

type EnrBuilder* = object
  seqNumber: uint64
  privateKey: eth_keys.PrivateKey
  fields: seq[FieldPair]

proc init*(T: type EnrBuilder, key: eth_keys.PrivateKey, seqNum: uint64 = 1): T =
  EnrBuilder(seqNumber: seqNum, privateKey: key, fields: newSeq[FieldPair]())

proc init*(T: type EnrBuilder, key: libp2p_crypto.PrivateKey, seqNum: uint64 = 1): T =
  # TODO: Inconvenient runtime assertion. Move this assertion to compile time
  if key.scheme != PKScheme.Secp256k1:
    raise newException(Defect, "invalid private key scheme")

  let
    bytes = key.getRawBytes().expect("Private key is valid")
    privateKey =
      eth_keys.PrivateKey.fromRaw(bytes).expect("Raw private key is of valid length")

  EnrBuilder.init(key = privateKey, seqNum = seqNum)

proc addFieldPair*(builder: var EnrBuilder, pair: FieldPair) =
  builder.fields.add(pair)

proc addFieldPair*[V](builder: var EnrBuilder, key: string, value: V) =
  builder.addFieldPair(toFieldPair(key, value))

proc build*(builder: EnrBuilder): EnrResult[enr.Record] =
  # Note that nim-eth's `Record.init` does not deduplicate the field pairs.
  # See: https://github.com/status-im/nim-eth/blob/4b22fcd/eth/p2p/discoveryv5/enr.nim#L143-L144
  enr.Record.init(
    seqNum = builder.seqNumber,
    pk = builder.privateKey,
    ip = none(IpAddress),
    tcpPort = none(Port),
    udpPort = none(Port),
    extraFields = builder.fields,
  )

## Builder extension: IP address and TCP/UDP ports

proc addAddressAndPorts(
    builder: var EnrBuilder, ip: IpAddress, tcpPort, udpPort: Option[Port]
) =
  # Based on: https://github.com/status-im/nim-eth/blob/4b22fcd/eth/p2p/discoveryv5/enr.nim#L166
  let isV6 = ip.family == IPv6

  let ipField =
    if isV6:
      toFieldPair("ip6", ip.address_v6)
    else:
      toFieldPair("ip", ip.address_v4)
  builder.addFieldPair(ipField)

  if tcpPort.isSome():
    let
      tcpPortFieldKey = if isV6: "tcp6" else: "tcp"
      tcpPortFieldValue = tcpPort.get()
    builder.addFieldPair(tcpPortFieldKey, tcpPortFieldValue.uint16)

  if udpPort.isSome():
    let
      udpPortFieldKey = if isV6: "udp6" else: "udp"
      udpPortFieldValue = udpPort.get()
    builder.addFieldPair(udpPortFieldKey, udpPortFieldValue.uint16)

proc addPorts(builder: var EnrBuilder, tcp, udp: Option[Port]) =
  # Based on: https://github.com/status-im/nim-eth/blob/4b22fcd/eth/p2p/discoveryv5/enr.nim#L166

  if tcp.isSome():
    let tcpPort = tcp.get()
    builder.addFieldPair("tcp", tcpPort.uint16)

  if udp.isSome():
    let udpPort = udp.get()
    builder.addFieldPair("udp", udpPort.uint16)

proc withIpAddressAndPorts*(
    builder: var EnrBuilder,
    ipAddr = none(IpAddress),
    tcpPort = none(Port),
    udpPort = none(Port),
) =
  if ipAddr.isSome():
    addAddressAndPorts(builder, ipAddr.get(), tcpPort, udpPort)
  else:
    addPorts(builder, tcpPort, udpPort)
