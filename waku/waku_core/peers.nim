{.push raises: [].}

import
  std/[options, sequtils, strutils, uri, net],
  results,
  chronos,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  eth/net/utils,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/errors,
  libp2p/multiaddress,
  libp2p/multicodec,
  libp2p/peerid,
  libp2p/peerinfo,
  libp2p/routing_record,
  json_serialization
import ../waku_enr/capabilities

type
  Connectedness* = enum
    # NotConnected: default state for a new peer. No connection and no further information on connectedness.
    NotConnected
    # CannotConnect: attempted to connect to peer, but failed.
    CannotConnect
    # CanConnect: was recently connected to peer and disconnected gracefully.
    CanConnect
    # Connected: actively connected to peer.
    Connected

  PeerOrigin* = enum
    UnknownOrigin
    Discv5
    Static
    PeerExchange
    Dns

  PeerDirection* = enum
    UnknownDirection
    Inbound
    Outbound

type RemotePeerInfo* = ref object
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

proc writeValue*(
    w: var JsonWriter, value: RemotePeerInfo
) {.inline, raises: [IOError].} =
  w.writeValue $value

proc init*(
    T: typedesc[RemotePeerInfo],
    peerId: PeerID,
    addrs: seq[MultiAddress] = @[],
    enr: Option[enr.Record] = none(enr.Record),
    protocols: seq[string] = @[],
    publicKey: crypto.PublicKey = crypto.PublicKey(),
    agent: string = "",
    protoVersion: string = "",
    connectedness: Connectedness = NotConnected,
    disconnectTime: int64 = 0,
    origin: PeerOrigin = UnknownOrigin,
    direction: PeerDirection = UnknownDirection,
    lastFailedConn: Moment = Moment.init(0, Second),
    numberFailedConn: int = 0,
): T =
  RemotePeerInfo(
    peerId: peerId,
    addrs: addrs,
    enr: enr,
    protocols: protocols,
    publicKey: publicKey,
    agent: agent,
    protoVersion: protoVersion,
    connectedness: connectedness,
    disconnectTime: disconnectTime,
    origin: origin,
    direction: direction,
    lastFailedConn: lastFailedConn,
    numberFailedConn: numberFailedConn,
  )

proc init*(
    T: typedesc[RemotePeerInfo],
    peerId: string,
    addrs: seq[MultiAddress] = @[],
    enr: Option[enr.Record] = none(enr.Record),
    protocols: seq[string] = @[],
): T {.raises: [Defect, ResultError[cstring], LPError].} =
  let peerId = PeerID.init(peerId).tryGet()
  RemotePeerInfo(peerId: peerId, addrs: addrs, enr: enr, protocols: protocols)

## Parse

proc validWireAddr*(ma: MultiAddress): bool =
  ## Check if wire Address is supported
  const ValidTransports = mapOr(TCP, WebSockets)
  return ValidTransports.match(ma)

proc parsePeerInfo*(peer: RemotePeerInfo): Result[RemotePeerInfo, string] =
  ## Parses a fully qualified peer multiaddr, in the
  ## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo
  ok(peer)

proc parsePeerInfo*(peer: MultiAddress): Result[RemotePeerInfo, string] =
  ## Parses a fully qualified peer multiaddr, in the
  ## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo
  var p2pPart: MultiAddress
  var wireAddr = MultiAddress()
  for addrPart in peer.items():
    case addrPart[].protoName()[]
    # All protocols listed here: https://github.com/multiformats/multiaddr/blob/b746a7d014e825221cc3aea6e57a92d78419990f/protocols.csv
    of "p2p":
      p2pPart =
        ?addrPart.mapErr(
          proc(err: string): string =
            "Error getting p2pPart [" & err & "]"
        )
    of "ip4", "ip6", "dns", "dnsaddr", "dns4", "dns6", "tcp", "ws", "wss":
      let val =
        ?addrPart.mapErr(
          proc(err: string): string =
            "Error getting addrPart [" & err & "]"
        )
      ?wireAddr.append(val).mapErr(
        proc(err: string): string =
          "Error appending addrPart [" & err & "]"
      )

  let p2pPartStr = p2pPart.toString().get()
  if not p2pPartStr.contains("/"):
    let msg =
      "Error in parsePeerInfo: p2p part should contain / [p2pPartStr:" & p2pPartStr &
      "] [peer:" & $peer & "]"
    return err(msg)

  let peerId =
    ?PeerID.init(p2pPartStr.split("/")[^1]).mapErr(
      proc(e: cstring): string =
        $e
    )

  if not wireAddr.validWireAddr():
    return err("invalid multiaddress: no supported transport found")

  return ok(RemotePeerInfo.init(peerId, @[wireAddr]))

proc parsePeerInfo*(peer: string): Result[RemotePeerInfo, string] =
  ## Parses a fully qualified peer multiaddr, in the
  ## format `(ip4|ip6)/tcp/p2p`, into dialable PeerInfo
  let multiAddr =
    ?MultiAddress.init(peer).mapErr(
      proc(err: string): string =
        "MultiAddress.init [" & err & "]"
    )

  parsePeerInfo(multiAddr)

func getTransportProtocol(typedR: TypedRecord): Option[IpTransportProtocol] =
  if typedR.tcp6.isSome() or typedR.tcp.isSome():
    return some(IpTransportProtocol.tcpProtocol)

  if typedR.udp6.isSome() or typedR.udp.isSome():
    return some(IpTransportProtocol.udpProtocol)

  return none(IpTransportProtocol)

proc parseUrlPeerAddr*(
    peerAddr: Option[string]
): Result[Option[RemotePeerInfo], string] =
  # Checks whether the peerAddr parameter represents a valid p2p multiaddress.
  # The param must be in the format `(ip4|ip6)/tcp/p2p/$peerId` but URL-encoded
  if not peerAddr.isSome() or peerAddr.get() == "":
    return ok(none(RemotePeerInfo))

  let parsedAddr = decodeUrl(peerAddr.get())
  let parsedPeerInfo = parsePeerInfo(parsedAddr)
  if parsedPeerInfo.isErr():
    return err("Failed parsing remote peer info [" & parsedPeerInfo.error & "]")

  return ok(some(parsedPeerInfo.value))

proc toRemotePeerInfo*(enr: enr.Record): Result[RemotePeerInfo, cstring] =
  ## Converts an ENR to dialable RemotePeerInfo
  let typedR = ?enr.toTypedRecord()
  if not typedR.secp256k1.isSome():
    return err("enr: no secp256k1 key in record")

  let
    pubKey = ?keys.PublicKey.fromRaw(typedR.secp256k1.get())
    peerId =
      ?PeerID.init(crypto.PublicKey(scheme: Secp256k1, skkey: secp.SkPublicKey(pubKey)))

  let transportProto = getTransportProtocol(typedR)
  if transportProto.isNone():
    return err("enr: could not determine transport protocol")

  var addrs = newSeq[MultiAddress]()
  case transportProto.get()
  of tcpProtocol:
    if typedR.ip.isSome() and typedR.tcp.isSome():
      let ip = ipv4(typedR.ip.get())
      addrs.add MultiAddress.init(ip, tcpProtocol, Port(typedR.tcp.get()))

    if typedR.ip6.isSome():
      let ip = ipv6(typedR.ip6.get())
      if typedR.tcp6.isSome():
        addrs.add MultiAddress.init(ip, tcpProtocol, Port(typedR.tcp6.get()))
      elif typedR.tcp.isSome():
        addrs.add MultiAddress.init(ip, tcpProtocol, Port(typedR.tcp.get()))
      else:
        discard
  of udpProtocol:
    if typedR.ip.isSome() and typedR.udp.isSome():
      let ip = ipv4(typedR.ip.get())
      addrs.add MultiAddress.init(ip, udpProtocol, Port(typedR.udp.get()))

    if typedR.ip6.isSome():
      let ip = ipv6(typedR.ip6.get())
      if typedR.udp6.isSome():
        addrs.add MultiAddress.init(ip, udpProtocol, Port(typedR.udp6.get()))
      elif typedR.udp.isSome():
        addrs.add MultiAddress.init(ip, udpProtocol, Port(typedR.udp.get()))
      else:
        discard

  if addrs.len == 0:
    return err("enr: no addresses in record")

  let protocolsRes = catch:
    enr.getCapabilitiesCodecs()

  var protocols: seq[string]
  if not protocolsRes.isErr():
    protocols = protocolsRes.get()

  return ok(RemotePeerInfo.init(peerId, addrs, some(enr), protocols))

converter toRemotePeerInfo*(peerRecord: PeerRecord): RemotePeerInfo =
  ## Converts peer records to dialable RemotePeerInfo
  ## Useful if signed peer records have been received in an exchange
  RemotePeerInfo.init(peerRecord.peerId, peerRecord.addresses.mapIt(it.address))

converter toRemotePeerInfo*(peerInfo: PeerInfo): RemotePeerInfo =
  ## Converts the local peerInfo to dialable RemotePeerInfo
  ## Useful for testing or internal connections
  RemotePeerInfo(
    peerId: peerInfo.peerId,
    addrs: peerInfo.listenAddrs,
    enr: none(Record),
    protocols: peerInfo.protocols,
    agent: peerInfo.agentVersion,
    protoVersion: peerInfo.protoVersion,
    publicKey: peerInfo.publicKey,
  )

proc hasProtocol*(ma: MultiAddress, proto: string): bool =
  ## Checks if a multiaddress contains a given protocol
  ## Useful for filtering multiaddresses based on their protocols
  ##
  ## Returns ``true`` if ``ma`` contains protocol ``proto``.
  let proto = MultiCodec.codec(proto)

  let protos = ma.protocols()
  if protos.isErr():
    return false

  return protos.get().anyIt(it == proto)

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
