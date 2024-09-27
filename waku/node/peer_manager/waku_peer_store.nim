{.push raises: [].}

import
  std/[tables, sequtils, sets, options, strutils],
  chronos,
  eth/p2p/discoveryv5/enr,
  libp2p/builders,
  libp2p/peerstore

import
  ../../waku_core,
  ../../waku_enr/sharding,
  ../../waku_enr/capabilities,
  ../../common/utils/sequence

export peerstore, builders

type
  WakuPeerStore* = ref object
    peerStore*: PeerStore

  # Keeps track of the Connectedness state of a peer
  ConnectionBook* = ref object of PeerBook[Connectedness]

  # Keeps track of the timestamp of the last failed connection attempt
  LastFailedConnBook* = ref object of PeerBook[Moment]

  # Keeps track of the number of failed connection attempts
  NumberFailedConnBook* = ref object of PeerBook[int]

  # Keeps track of when peers were disconnected in Unix timestamps
  DisconnectBook* = ref object of PeerBook[int64]

  # Keeps track of the origin of a peer
  SourceBook* = ref object of PeerBook[PeerOrigin]

  # Keeps track of the direction of a peer connection
  DirectionBook* = ref object of PeerBook[PeerDirection]

  # Keeps track of the ENR (Ethereum Node Record) of a peer
  ENRBook* = ref object of PeerBook[enr.Record]

# Constructor
proc new*(T: type WakuPeerStore, identify: Identify, capacity = 1000): WakuPeerStore =
  let peerStore = PeerStore.new(identify, capacity)
  WakuPeerStore(peerStore: peerStore)

# Core functionality
proc `[]`*(wps: WakuPeerStore, T: typedesc): T =
  wps.peerStore[T]

proc getPeer*(wps: WakuPeerStore, peerId: PeerId): RemotePeerInfo =
  RemotePeerInfo(
    peerId: peerId,
    addrs: wps[AddressBook][peerId],
    enr:
      if wps[ENRBook][peerId] != default(enr.Record):
        some(wps[ENRBook][peerId])
      else:
        none(enr.Record)
    ,
    protocols: wps[ProtoBook][peerId],
    agent: wps[AgentBook][peerId],
    protoVersion: wps[ProtoVersionBook][peerId],
    publicKey: wps[KeyBook][peerId],
    connectedness: wps[ConnectionBook][peerId],
    disconnectTime: wps[DisconnectBook][peerId],
    origin: wps[SourceBook][peerId],
    direction: wps[DirectionBook][peerId],
    lastFailedConn: wps[LastFailedConnBook][peerId],
    numberFailedConn: wps[NumberFailedConnBook][peerId],
  )

proc addPeer*(wps: WakuPeerStore, peer: RemotePeerInfo) =
  wps[AddressBook][peer.peerId] = peer.addrs
  wps[ProtoBook][peer.peerId] = peer.protocols
  wps[AgentBook][peer.peerId] = peer.agent
  wps[ProtoVersionBook][peer.peerId] = peer.protoVersion
  wps[KeyBook][peer.peerId] = peer.publicKey
  wps[ConnectionBook][peer.peerId] = peer.connectedness
  wps[DisconnectBook][peer.peerId] = peer.disconnectTime
  wps[SourceBook][peer.peerId] = peer.origin
  wps[DirectionBook][peer.peerId] = peer.direction
  wps[LastFailedConnBook][peer.peerId] = peer.lastFailedConn
  wps[NumberFailedConnBook][peer.peerId] = peer.numberFailedConn
  if peer.enr.isSome():
    wps[ENRBook][peer.peerId] = peer.enr.get()

proc delete*(wps: WakuPeerStore, peerId: PeerId) =
  # Delete all the information of a given peer.
  wps.peerStore.del(peerId)

# TODO: Rename peers() to getPeersByProtocol()
proc peers*(wps: WakuPeerStore): seq[RemotePeerInfo] =
  let allKeys = concat(
      toSeq(wps[AddressBook].book.keys()),
      toSeq(wps[ProtoBook].book.keys()),
      toSeq(wps[KeyBook].book.keys()),
    )
    .toHashSet()

  return allKeys.mapIt(wps.getPeer(it))

proc peers*(wps: WakuPeerStore, proto: string): seq[RemotePeerInfo] =
  wps.peers().filterIt(it.protocols.contains(proto))

proc peers*(wps: WakuPeerStore, protocolMatcher: Matcher): seq[RemotePeerInfo] =
  wps.peers().filterIt(it.protocols.anyIt(protocolMatcher(it)))

proc connectedness*(wps: WakuPeerStore, peerId: PeerId): Connectedness =
  wps[ConnectionBook].book.getOrDefault(peerId, NotConnected)

proc hasShard*(wps: WakuPeerStore, peerId: PeerID, cluster, shard: uint16): bool =
  wps[ENRBook].book.getOrDefault(peerId).containsShard(cluster, shard)

proc hasCapability*(wps: WakuPeerStore, peerId: PeerID, cap: Capabilities): bool =
  wps[ENRBook].book.getOrDefault(peerId).supportsCapability(cap)

proc peerExists*(wps: WakuPeerStore, peerId: PeerId): bool =
  wps[AddressBook].contains(peerId)

proc isConnected*(wps: WakuPeerStore, peerId: PeerID): bool =
  # Returns `true` if the peer is connected
  wps.connectedness(peerId) == Connected

proc hasPeer*(wps: WakuPeerStore, peerId: PeerID, proto: string): bool =
  # Returns `true` if peer is included in manager for the specified protocol
  # TODO: What if peer does not exist in the wps?
  wps.getPeer(peerId).protocols.contains(proto)

proc hasPeers*(wps: WakuPeerStore, proto: string): bool =
  # Returns `true` if the peerstore has any peer for the specified protocol
  toSeq(wps[ProtoBook].book.values()).anyIt(it.anyIt(it == proto))

proc hasPeers*(wps: WakuPeerStore, protocolMatcher: Matcher): bool =
  # Returns `true` if the peerstore has any peer matching the protocolMatcher
  toSeq(wps[ProtoBook].book.values()).anyIt(it.anyIt(protocolMatcher(it)))

proc getCapacity*(wps: WakuPeerStore): int =
  wps.peerStore.capacity

proc setCapacity*(wps: WakuPeerStore, capacity: int) =
  wps.peerStore.capacity = capacity

proc getWakuProtos*(wps: WakuPeerStore): seq[string] =
  toSeq(wps[ProtoBook].book.values()).flatten().deduplicate().filterIt(
    it.startsWith("/vac/waku")
  )

proc getPeersByDirection*(
    wps: WakuPeerStore, direction: PeerDirection
): seq[RemotePeerInfo] =
  return wps.peers.filterIt(it.direction == direction)

proc getDisconnectedPeers*(wps: WakuPeerStore): seq[RemotePeerInfo] =
  return wps.peers.filterIt(it.connectedness != Connected)

proc getConnectedPeers*(wps: WakuPeerStore): seq[RemotePeerInfo] =
  return wps.peers.filterIt(it.connectedness == Connected)

proc getPeersByProtocol*(wps: WakuPeerStore, proto: string): seq[RemotePeerInfo] =
  return wps.peers.filterIt(it.protocols.contains(proto))

proc getReachablePeers*(wps: WakuPeerStore): seq[RemotePeerInfo] =
  return
    wps.peers.filterIt(it.connectedness == CanConnect or it.connectedness == Connected)

proc getPeersByShard*(wps: WakuPeerStore, cluster, shard: uint16): seq[RemotePeerInfo] =
  return
    wps.peers.filterIt(it.enr.isSome() and it.enr.get().containsShard(cluster, shard))

proc getPeersByCapability*(wps: WakuPeerStore, cap: Capabilities): seq[RemotePeerInfo] =
  return wps.peers.filterIt(it.enr.isSome() and it.enr.get().supportsCapability(cap))
