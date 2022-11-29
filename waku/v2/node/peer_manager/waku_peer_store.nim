when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables, sequtils, sets, options],
  libp2p/builders,
  libp2p/peerstore

import
  ../../utils/peers

export peerstore, builders

# TODO rename to peer_store_extended to emphasize its a nimlibp2 extension

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

  Direction* = enum
    UnknownDirection,
    Inbound,
    Outbound

  # Keeps track of the Connectedness state of a peer
  ConnectionBook* = ref object of PeerBook[Connectedness]

  # Keeps track of when peers were disconnected in Unix timestamps
  DisconnectBook* = ref object of PeerBook[int64]

  # Keeps track of the origin of a peer
  SourceBook* = ref object of PeerBook[PeerOrigin]

  # Direction
  DirectionBook* = ref object of PeerBook[Direction]

  StoredInfo* = object
    # Taken from nim-libp2
    peerId*: PeerId
    addrs*: seq[MultiAddress]
    protos*: seq[string]
    publicKey*: PublicKey
    agent*: string
    protoVersion*: string

    # Extended custom fields
    connectedness*: Connectedness
    disconnectTime*: int64
    origin*: PeerOrigin
    direction*: Direction

##################
# Peer Store API #
##################

proc get*(peerStore: PeerStore,
          peerId: PeerID): StoredInfo =
  ## Get the stored information of a given peer.
  StoredInfo(
    # Taken from nim-libp2
    peerId: peerId,
    addrs: peerStore[AddressBook][peerId],
    protos: peerStore[ProtoBook][peerId],
    publicKey: peerStore[KeyBook][peerId],
    agent: peerStore[AgentBook][peerId],
    protoVersion: peerStore[ProtoVersionBook][peerId],

    # Extended custom fields
    connectedness: peerStore[ConnectionBook][peerId],
    disconnectTime: peerStore[DisconnectBook][peerId],
    origin: peerStore[SourceBook][peerId],
    direction: peerStore[DirectionBook][peerId],
  )

# TODO: Rename peers() to getPeersByProtocol()
proc peers*(peerStore: PeerStore): seq[StoredInfo] =
  ## Get all the stored information of every peer.
  let allKeys = concat(toSeq(peerStore[AddressBook].book.keys()),
                       toSeq(peerStore[ProtoBook].book.keys()),
                       toSeq(peerStore[KeyBook].book.keys())).toHashSet()

  return allKeys.mapIt(peerStore.get(it))

proc peers*(peerStore: PeerStore, proto: string): seq[StoredInfo] =
  # Return the known info for all peers registered on the specified protocol
  peerStore.peers.filterIt(it.protos.contains(proto))

proc peers*(peerStore: PeerStore, protocolMatcher: Matcher): seq[StoredInfo] =
  # Return the known info for all peers matching the provided protocolMatcher
  peerStore.peers.filterIt(it.protos.anyIt(protocolMatcher(it)))

proc toRemotePeerInfo*(storedInfo: StoredInfo): RemotePeerInfo =
  RemotePeerInfo.init(peerId = storedInfo.peerId,
                      addrs = toSeq(storedInfo.addrs),
                      protocols = toSeq(storedInfo.protos))


proc connectedness*(peerStore: PeerStore, peerId: PeerID): Connectedness =
  # Return the connection state of the given, managed peer
  # TODO: the PeerManager should keep and update local connectedness state for peers, redial on disconnect, etc.
  # TODO: richer return than just bool, e.g. add enum "CanConnect", "CannotConnect", etc. based on recent connection attempts
  return peerStore[ConnectionBook].book.getOrDefault(peerId, NotConnected)

proc hasPeer*(peerStore: PeerStore, peerId: PeerID, proto: string): bool =
  # Returns `true` if peer is included in manager for the specified protocol
  # TODO: What if peer does not exist in the peerStore?
  peerStore.get(peerId).protos.contains(proto)

proc hasPeers*(peerStore: PeerStore, proto: string): bool =
  # Returns `true` if the peerstore has any peer for the specified protocol
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(it == proto))

proc hasPeers*(peerStore: PeerStore, protocolMatcher: Matcher): bool =
  # Returns `true` if the peerstore has any peer matching the protocolMatcher
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(protocolMatcher(it)))

proc selectPeer*(peerStore: PeerStore, proto: string): Option[RemotePeerInfo] =
  # Selects the best peer for a given protocol
  let peers = peerStore.peers().filterIt(it.protos.contains(proto))

  if peers.len >= 1:
     # TODO: proper heuristic here that compares peer scores and selects "best" one. For now the first peer for the given protocol is returned
    let peerStored = peers[0]

    return some(peerStored.toRemotePeerInfo())
  else:
    return none(RemotePeerInfo)

proc getPeersByDirection*(peerStore: PeerStore, direction: Direction): seq[StoredInfo] =
  return peerStore.peers().filterIt(it.direction == direction)
