when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

# Collection of utilities related to Waku peers
import
  std/[options, sequtils, strutils, uri],
  chronos,
  stew/results,
  stew/shims/net,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/[crypto, secp],
  libp2p/[errors,
          multiaddress,
          multicodec,
          peerid,
          peerinfo,
          routing_record]

#import
#  ../node/peer_manager/waku_peer_store
# todo organize this

type
  Connectedness* = enum
    # NotConnected: default state for a new peer. No connection and no further information on connectedness.
    NotConnected,
    # CannotConnect: attempted to connect to peer, but failed.
    CannotConnect,
    # CanConnect: was recently connected to peer and disconnected gracefully.
    CanConnect,
    # Connected: actively connected to peer.
    Connected

  PeerOrigin* = enum
    UnknownOrigin,
    Discv5,
    Static,
    Dns

  PeerDirection* = enum
    UnknownDirection,
    Inbound,
    Outbound

type
  RemotePeerInfo* = ref object of RootObj
    peerId*: PeerID
    addrs*: seq[MultiAddress]
    enr*: Option[enr.Record]
    protocols*: seq[string]

    agent*: string
    protoVersion*: string
    publicKey*: crypto.PublicKey
    connectedness*: Connectedness
    disconnectTime*: int64
    origin*: PeerOrigin
    direction*: PeerDirection
    lastFailedConn*: Moment
    numberFailedConn*: int

func `$`*(remotePeerInfo: RemotePeerInfo): string =
  $remotePeerInfo.peerId

proc init*(
  p: typedesc[RemotePeerInfo],
  peerId: PeerID,
  addrs: seq[MultiAddress] = @[],
  enr: Option[enr.Record] = none(enr.Record),
  protocols: seq[string] = @[]): RemotePeerInfo =

  let remotePeerInfo = RemotePeerInfo(
    peerId: peerId,
    addrs: addrs,
    enr: enr,
    protocols: protocols)

  return remotePeerInfo

proc init*(p: typedesc[RemotePeerInfo],
           peerId: string,
           addrs: seq[MultiAddress] = @[],
           enr: Option[enr.Record] = none(enr.Record),
           protocols: seq[string] = @[]): RemotePeerInfo
           {.raises: [Defect, ResultError[cstring], LPError].} =

  let remotePeerInfo = RemotePeerInfo(
    peerId: PeerID.init(peerId).tryGet(),
    addrs: addrs,
    enr: enr,
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


proc parsePeerInfo*(peer: RemotePeerInfo|string):
                    Result[RemotePeerInfo, string] =
  ## Parses a fully qualified peer multiaddr, in the
  ## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo

  if peer is RemotePeerInfo:
    return ok(cast[RemotePeerInfo](peer))

  let multiAddr = ? MultiAddress.init(cast[string](peer))
                    .mapErr(proc(err: string):
                        string = "MultiAddress.init [" & err & "]")

  var p2pPart: MultiAddress
  var wireAddr = MultiAddress()
  for addrPart in multiAddr.items():
    case addrPart[].protoName()[]
    # All protocols listed here: https://github.com/multiformats/multiaddr/blob/b746a7d014e825221cc3aea6e57a92d78419990f/protocols.csv
    of "p2p":
      p2pPart = ? addrPart.mapErr(proc(err: string):string = "Error getting p2pPart [" & err & "]")
    of "ip4", "ip6", "dns", "dnsaddr", "dns4", "dns6", "tcp", "ws", "wss":
      let val = ? addrPart.mapErr(proc(err: string):string = "Error getting addrPart [" & err & "]")
      ? wireAddr.append(val).mapErr(proc(err: string):string = "Error appending addrPart [" & err & "]")

  let p2pPartStr = p2pPart.toString()[]
  if not p2pPartStr.contains("/"):
    return err("Error in parsePeerInfo: p2p part should contain /")

  let peerId = ? PeerID.init(p2pPartStr.split("/")[^1])
                        .mapErr(proc (e:cstring):string = cast[string](e))

  if not wireAddr.validWireAddr():
    return err("Error in parsePeerInfo: Invalid node multiaddress")

  return ok(RemotePeerInfo.init(peerId, @[wireAddr]))


# Checks whether the peerAddr parameter represents a valid p2p multiaddress.
# The param must be in the format `(ip4|ip6)/tcp/p2p/$peerId` but URL-encoded
proc parseUrlPeerAddr*(peerAddr: Option[string]):
                       Result[Option[RemotePeerInfo], string] =

  if not peerAddr.isSome() or peerAddr.get() == "":
    return ok(none(RemotePeerInfo))

  let parsedAddr = decodeUrl(peerAddr.get())
  let parsedPeerInfo = parsePeerInfo(parsedAddr)

  if parsedPeerInfo.isOk():
    return ok(some(parsedPeerInfo.value))
  else:
    return err("Failed parsing remote peer info [" &
               parsedPeerInfo.error & "]")

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

  return ok(RemotePeerInfo.init(peerId, addrs, some(enr)))

## Converts peer records to dialable RemotePeerInfo
## Useful if signed peer records have been received in an exchange
proc toRemotePeerInfo*(peerRecord: PeerRecord): RemotePeerInfo =
  RemotePeerInfo.init(peerRecord.peerId,
                      peerRecord.addresses.mapIt(it.address))

## Converts the local peerInfo to dialable RemotePeerInfo
## Useful for testing or internal connections
proc toRemotePeerInfo*(peerInfo: PeerInfo): RemotePeerInfo =
  RemotePeerInfo.init(peerInfo.peerId,
                      peerInfo.listenAddrs,
                      none(enr.Record), # we could generate an ENR from PeerInfo
                      peerInfo.protocols)

## Checks if a multiaddress contains a given protocol
## Useful for filtering multiaddresses based on their protocols
proc hasProtocol*(ma: MultiAddress, proto: string): bool =
  ## Returns ``true`` if ``ma`` contains protocol ``proto``.
  let protos = ma.protocols()
  if protos.isErr():
    return false
  for p in protos.get():
    if p == MultiCodec.codec(proto):
      return true
  return false

func hasUdpPort*(peer: RemotePeerInfo): bool =
  if peer.enr.isNone():
   return false

  let
    enr = peer.enr.get()
    typedEnrRes = enr.toTypedRecord()

  if typedEnrRes.isErr():
    return false

  let typedEnr = typedEnrRes.get()
  typedEnr.udp.isSome() or typedEnr.udp6.isSome()

