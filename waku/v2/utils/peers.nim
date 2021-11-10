{.push raises: [Defect].}

# Collection of utilities related to Waku peers
import
  std/[options, strutils],
  stew/results,
  stew/shims/net,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/[crypto, secp],
  libp2p/[errors,
          multiaddress,
          peerid,
          peerinfo]

type
  RemotePeerInfo* = ref object of RootObj
    peerId*: PeerID
    addrs*: seq[MultiAddress]
    protocols*: seq[string]

func `$`*(remotePeerInfo: RemotePeerInfo): string =
  $remotePeerInfo.peerId

proc init*(
  p: typedesc[RemotePeerInfo],
  peerId: PeerID,
  addrs: seq[MultiAddress] = @[],
  protocols: seq[string] = @[]): RemotePeerInfo =

  let remotePeerInfo = RemotePeerInfo(
    peerId: peerId,
    addrs: addrs,
    protocols: protocols)
  
  return remotePeerInfo

proc init*(p: typedesc[RemotePeerInfo],
           peerId: string,
           addrs: seq[MultiAddress] = @[],
           protocols: seq[string] = @[]): RemotePeerInfo
           {.raises: [Defect, ResultError[cstring], LPError].} =
  
  let remotePeerInfo = RemotePeerInfo(
    peerId: PeerID.init(peerId).tryGet(),
    addrs: addrs,
    protocols: protocols)

  return remotePeerInfo

## Check if wire Address is supported
proc validWireAddr*(ma: MultiAddress): bool =
  const
    ValidTransports = mapOr(TCP, WebSockets)
  return ValidTransports.match(ma)

func getTransportProtocol(typedR: TypedRecord): Option[IpTransportProtocol] =
  if typedR.tcp6.isSome or typedR.tcp.isSome:
    return some(IpTransportProtocol.tcpProtocol)

  if typedR.udp6.isSome or typedR.udp.isSome:
    return some(IpTransportProtocol.udpProtocol)

  return none(IpTransportProtocol)

## Parses a fully qualified peer multiaddr, in the
## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo
proc parseRemotePeerInfo*(address: string): RemotePeerInfo {.raises: [Defect, ValueError, LPError].}=
  let multiAddr = MultiAddress.init(address).tryGet()

  var

    ipPart, tcpPart, p2pPart, wsPart, wssPart: MultiAddress

  for addrPart in multiAddr.items():
    case addrPart[].protoName()[]
    of "ip4", "ip6":
      ipPart = addrPart.tryGet()
    of "tcp":
      tcpPart = addrPart.tryGet()
    of "p2p":
      p2pPart = addrPart.tryGet()
    of "ws":
      wsPart = addrPart.tryGet()
    of "wss":
      wssPart = addrPart.tryGet()

  # nim-libp2p dialing requires remote peers to be initialised with a peerId and a wire address
  let
    peerIdStr = p2pPart.toString()[].split("/")[^1] 

    wireAddr = ipPart & tcpPart & wsPart & wssPart
  if (not wireAddr.validWireAddr()):
    raise newException(ValueError, "Invalid node multi-address")

  return RemotePeerInfo.init(peerIdStr, @[wireAddr])

## Converts an ENR to dialable RemotePeerInfo
proc toRemotePeerInfo*(enr: enr.Record): Result[RemotePeerInfo, cstring] =
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

  return ok(RemotePeerInfo.init(peerId, addrs))

## Converts the local peerInfo to dialable RemotePeerInfo
## Useful for testing or internal connections
proc toRemotePeerInfo*(peerInfo: PeerInfo): RemotePeerInfo =
  RemotePeerInfo.init(peerInfo.peerId,
                      peerInfo.addrs,
                      peerInfo.protocols)
