{.push raises: [Defect].}

## A set of utilities to integrate EIP-1459 DNS-based discovery
## for Waku v2 nodes

import
  std/options,
  stew/shims/net,
  chronos,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/peerinfo,
  libp2p/multiaddress,
  discovery/dnsdisc/client

export client, enr

type
  WakuDnsDiscovery* = object
    enr*: enr.Record
    client*: Client
    resolver*: Resolver

##################
# Util functions #
##################

func getTransportProtocol(typedR: TypedRecord): Option[IpTransportProtocol] =
  if typedR.tcp6.isSome or typedR.tcp.isSome:
    return some(IpTransportProtocol.tcpProtocol)

  if typedR.udp6.isSome or typedR.udp.isSome:
    return some(IpTransportProtocol.udpProtocol)

  return none(IpTransportProtocol)

func toPeerInfo*(enr: enr.Record): Result[PeerInfo, cstring] =
  let typedR = ? enr.toTypedRecord

  if not typedR.secp256k1.isSome:
    return err("enr: no secp256k1 key in record")
  
  let
    pubKey = ? keys.PublicKey.fromRaw(typedR.secp256k1.get)
    peerId = ? PeerID.init(crypto.PublicKey(scheme: Secp256k1,
                                            skkey: secp.SkPublicKey(pubKey)))
  
  var addrs = newSeq[MultiAddress]()

  let transportProto = getTransportProtocol(typedR)
  if transportProto.isNone:
    return err("enr: could not determine transport protocol")

  case transportProto.get()
  of tcpProtocol:
    if typedR.ip.isSome and typedR.tcp.isSome:
      let ip = ipv4(typedR.ip.get)
      addrs.add MultiAddress.init(ip, tcpProtocol, Port typedR.tcp.get)

    if typedR.ip6.isSome:
      let ip = ipv6(typedR.ip6.get)
      if typedR.tcp6.isSome:
        addrs.add MultiAddress.init(ip, tcpProtocol, Port typedR.tcp6.get)
      elif typedR.tcp.isSome:
        addrs.add MultiAddress.init(ip, tcpProtocol, Port typedR.tcp.get)
      else:
        discard

  of udpProtocol:
    if typedR.ip.isSome and typedR.udp.isSome:
      let ip = ipv4(typedR.ip.get)
      addrs.add MultiAddress.init(ip, udpProtocol, Port typedR.udp.get)

    if typedR.ip6.isSome:
      let ip = ipv6(typedR.ip6.get)
      if typedR.udp6.isSome:
        addrs.add MultiAddress.init(ip, udpProtocol, Port typedR.udp6.get)
      elif typedR.udp.isSome:
        addrs.add MultiAddress.init(ip, udpProtocol, Port typedR.udp.get)
      else:
        discard

  if addrs.len == 0:
    return err("enr: no addresses in record")

  return ok(PeerInfo.init(peerId, addrs))

func createEnr*(privateKey: crypto.PrivateKey,
                enrIp: Option[ValidIpAddress],
                enrTcpPort, enrUdpPort: Option[Port]): enr.Record =
  
  assert privateKey.scheme == PKScheme.Secp256k1

  let
    rawPk = privateKey.getRawBytes().expect("Private key is valid")
    pk = keys.PrivateKey.fromRaw(rawPk).expect("Raw private key is of valid length")
    enr = enr.Record.init(1, pk, enrIp, enrTcpPort, enrUdpPort).expect("Record within size limits")
  
  return enr

#####################
# DNS Discovery API #
#####################

proc emptyResolver*(domain: string): Future[string] {.async, gcsafe.} =
  return ""

proc findPeers*(wdd: var WakuDnsDiscovery): Result[seq[PeerInfo], cstring] =
  ## Find peers to connect to using DNS based discovery
  
  # Synchronise client tree using configured resolver
  var tree: Tree
  try:
    tree = wdd.client.getTree(wdd.resolver)  # @TODO: this is currently a blocking operation to not violate memory safety
  except Exception:
    return err("Node discovery failed")

  var discoveredNodes: seq[PeerInfo]

  for enr in wdd.client.getNodeRecords():
    # Convert discovered ENR to PeerInfo and add to discovered nodes
    let res = enr.toPeerInfo()

    if res.isOk():
      discoveredNodes.add(res.get())

  return ok(discoveredNodes)

proc init*(T: type WakuDnsDiscovery,
           enr: enr.Record,
           locationUrl: string,
           resolver: Resolver): Result[T, cstring] =
  ## Initialise Waku peer discovery via DNS
  
  let
    client = ? Client.init(locationUrl)
    wakuDnsDisc = WakuDnsDiscovery(enr: enr, client: client, resolver: resolver)

  return ok(wakuDnsDisc)
