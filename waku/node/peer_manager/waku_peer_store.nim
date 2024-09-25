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
    store*: PeerStore

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

proc getCapacity*(wps: WakuPeerStore): int =
  wps.store.capacity

proc `[]`*(wps: WakuPeerStore, T: typedesc): T =
  wps.store[T]

proc delete*(wps: WakuPeerStore, peerId: PeerId) =
  # Delete all the information of a given peer.
  wps.store.del(peerId)

proc get*(wps: WakuPeerStore, peerId: PeerId): RemotePeerInfo =
  RemotePeerInfo(
    peerId: peerId,
    addrs: wps.store[AddressBook][peerId],
    enr:
      if wps.store[ENRBook].book.hasKey(peerId):
        some(wps.store[ENRBook][peerId])
      else:
        none(enr.Record)
    ,
    protocols: wps.store[ProtoBook][peerId],
    agent: wps.store[AgentBook][peerId],
    protoVersion: wps.store[ProtoVersionBook][peerId],
    publicKey: wps.store[KeyBook][peerId],
    connectedness: wps.store[ConnectionBook][peerId],
    disconnectTime: wps.store[DisconnectBook][peerId],
    origin: wps.store[SourceBook][peerId],
    direction: wps.store[DirectionBook][peerId],
    lastFailedConn: wps.store[LastFailedConnBook][peerId],
    numberFailedConn: wps.store[NumberFailedConnBook][peerId],
  )

proc getWakuProtos*(wps: WakuPeerStore): seq[string] =
  toSeq(wps.store[ProtoBook].book.values()).flatten().deduplicate().filterIt(
    it.startsWith("/vac/waku")
  )

# TODO: Rename peers() to getPeersByProtocol()
proc peers*(wps: WakuPeerStore): seq[RemotePeerInfo] =
  let allKeys = concat(
      toSeq(wps.store[AddressBook].book.keys()),
      toSeq(wps.store[ProtoBook].book.keys()),
      toSeq(wps.store[KeyBook].book.keys()),
    )
    .toHashSet()

  return allKeys.mapIt(wps.get(it))

proc peers*(wps: WakuPeerStore, proto: string): seq[RemotePeerInfo] =
  wps.peers().filterIt(it.protocols.contains(proto))

proc peers*(wps: WakuPeerStore, protocolMatcher: Matcher): seq[RemotePeerInfo] =
  wps.peers().filterIt(it.protocols.anyIt(protocolMatcher(it)))

proc connectedness*(wps: WakuPeerStore, peerId: PeerId): Connectedness =
  wps.store[ConnectionBook].book.getOrDefault(peerId, NotConnected)

proc hasShard*(peerStore: WakuPeerStore, peerId: PeerID, cluster, shard: uint16): bool =
  peerStore[ENRBook].book.getOrDefault(peerId).containsShard(cluster, shard)

proc hasCapability*(peerStore: WakuPeerStore, peerId: PeerID, cap: Capabilities): bool =
  peerStore[ENRBook].book.getOrDefault(peerId).supportsCapability(cap)

proc isConnected*(peerStore: WakuPeerStore, peerId: PeerID): bool =
  # Returns `true` if the peer is connected
  peerStore.connectedness(peerId) == Connected

proc hasPeer*(peerStore: WakuPeerStore, peerId: PeerID, proto: string): bool =
  # Returns `true` if peer is included in manager for the specified protocol
  # TODO: What if peer does not exist in the peerStore?
  peerStore.get(peerId).protocols.contains(proto)

proc hasPeers*(peerStore: WakuPeerStore, proto: string): bool =
  # Returns `true` if the peerstore has any peer for the specified protocol
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(it == proto))

proc hasPeers*(peerStore: WakuPeerStore, protocolMatcher: Matcher): bool =
  # Returns `true` if the peerstore has any peer matching the protocolMatcher
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(protocolMatcher(it)))

proc getPeersByDirection*(
    peerStore: WakuPeerStore, direction: PeerDirection
): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.direction == direction)

proc getNotConnectedPeers*(peerStore: WakuPeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness != Connected)

proc getConnectedPeers*(peerStore: WakuPeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness == Connected)

proc getPeersByProtocol*(peerStore: WakuPeerStore, proto: string): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.protocols.contains(proto))

proc getReachablePeers*(peerStore: WakuPeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(
    it.connectedness == CanConnect or it.connectedness == Connected
  )

proc getPeersByShard*(
    peerStore: WakuPeerStore, cluster, shard: uint16
): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(
    it.enr.isSome() and it.enr.get().containsShard(cluster, shard)
  )

proc getPeersByCapability*(
    peerStore: WakuPeerStore, cap: Capabilities
): seq[RemotePeerInfo] =
  return
    peerStore.peers.filterIt(it.enr.isSome() and it.enr.get().supportsCapability(cap))
