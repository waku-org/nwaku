import
  sequtils,
  stew/results,
  stew/shims/net,
  chronos,
  libp2p/crypto/crypto as libp2p_keys,
  eth/keys as eth_keys

import
  ../../../waku/
    [waku_core/topics, waku_enr, node/discovery_manager/waku_discv5, waku_enr/sharding],
  ../testlib/[common, wakucore]

proc newTestEnrRecord*(
    privKey: libp2p_keys.PrivateKey,
    extIp: string,
    tcpPort: uint16,
    udpPort: uint16,
    indices: seq[uint64] = @[],
    flags = none(CapabilitiesBitfield),
): waku_enr.Record =
  var builder = EnrBuilder.init(privKey)
  builder.withIpAddressAndPorts(
    ipAddr = some(parseIpAddress(extIp)),
    tcpPort = some(Port(tcpPort)),
    udpPort = some(Port(udpPort)),
  )

  if indices.len > 0:
    let
      byteSeq: seq[byte] = indices.mapIt(cast[byte](it))
      relayShards = fromIndicesList(byteSeq).get()
    discard builder.withWakuRelayShardingIndicesList(relayShards)

  if flags.isSome():
    builder.withWakuCapabilities(flags.get())

  builder.build().tryGet()
