when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables, sequtils, sets, options, times, strutils],
  chronos,
  eth/p2p/discoveryv5/enr,
  libp2p/builders,
  libp2p/peerstore

import
  ../../waku_core,
  ../../common/utils/sequence

export peerstore, builders

type

  # Keeps track of the Connectedness state of a peer
  ConnectionBook* = ref object of PeerBook[Connectedness]

  # Last failed connection attemp timestamp
  LastFailedConnBook* = ref object of PeerBook[Moment]

  # Failed connection attempts
  NumberFailedConnBook* = ref object of PeerBook[int]

  # Keeps track of when peers were disconnected in Unix timestamps
  DisconnectBook* = ref object of PeerBook[int64]

  # Keeps track of the origin of a peer
  SourceBook* = ref object of PeerBook[PeerOrigin]

  # Direction
  DirectionBook* = ref object of PeerBook[PeerDirection]

  # ENR Book
  ENRBook* = ref object of PeerBook[enr.Record]

##################
# Peer Store API #
##################

proc delete*(peerStore: PeerStore,
             peerId: PeerId) =
  # Delete all the information of a given peer.
  peerStore.del(peerId)

proc get*(peerStore: PeerStore,
          peerId: PeerID): RemotePeerInfo =
  ## Get the stored information of a given peer.
  RemotePeerInfo(
    peerId: peerId,
    addrs: peerStore[AddressBook][peerId],
    enr: if peerStore[ENRBook][peerId] != default(enr.Record): some(peerStore[ENRBook][peerId]) else: none(enr.Record),
    protocols: peerStore[ProtoBook][peerId],
    agent: peerStore[AgentBook][peerId],
    protoVersion: peerStore[ProtoVersionBook][peerId],
    publicKey: peerStore[KeyBook][peerId],

    # Extended custom fields
    connectedness: peerStore[ConnectionBook][peerId],
    disconnectTime: peerStore[DisconnectBook][peerId],
    origin: peerStore[SourceBook][peerId],
    direction: peerStore[DirectionBook][peerId],
    lastFailedConn: peerStore[LastFailedConnBook][peerId],
    numberFailedConn: peerStore[NumberFailedConnBook][peerId]
  )

proc getWakuProtos*(peerStore: PeerStore): seq[string] =
  ## Get the waku protocols of all the stored peers.
  let wakuProtocols = toSeq(peerStore[ProtoBook].book.values())
                        .flatten()
                        .deduplicate()
                        .filterIt(it.startsWith("/vac/waku"))
  return wakuProtocols

# TODO: Rename peers() to getPeersByProtocol()
proc peers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  ## Get all the stored information of every peer.
  let allKeys = concat(toSeq(peerStore[AddressBook].book.keys()),
                       toSeq(peerStore[ProtoBook].book.keys()),
                       toSeq(peerStore[KeyBook].book.keys())).toHashSet()

  return allKeys.mapIt(peerStore.get(it))

proc peers*(peerStore: PeerStore, proto: string): seq[RemotePeerInfo] =
  # Return the known info for all peers registered on the specified protocol
  peerStore.peers.filterIt(it.protocols.contains(proto))

proc peers*(peerStore: PeerStore, protocolMatcher: Matcher): seq[RemotePeerInfo] =
  # Return the known info for all peers matching the provided protocolMatcher
  peerStore.peers.filterIt(it.protocols.anyIt(protocolMatcher(it)))

proc connectedness*(peerStore: PeerStore, peerId: PeerID): Connectedness =
  # Return the connection state of the given, managed peer
  # TODO: the PeerManager should keep and update local connectedness state for peers, redial on disconnect, etc.
  # TODO: richer return than just bool, e.g. add enum "CanConnect", "CannotConnect", etc. based on recent connection attempts
  return peerStore[ConnectionBook].book.getOrDefault(peerId, NotConnected)

proc isConnected*(peerStore: PeerStore, peerId: PeerID): bool =
  # Returns `true` if the peer is connected
  peerStore.connectedness(peerId) == Connected

proc hasPeer*(peerStore: PeerStore, peerId: PeerID, proto: string): bool =
  # Returns `true` if peer is included in manager for the specified protocol
  # TODO: What if peer does not exist in the peerStore?
  peerStore.get(peerId).protocols.contains(proto)

proc hasPeers*(peerStore: PeerStore, proto: string): bool =
  # Returns `true` if the peerstore has any peer for the specified protocol
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(it == proto))

proc hasPeers*(peerStore: PeerStore, protocolMatcher: Matcher): bool =
  # Returns `true` if the peerstore has any peer matching the protocolMatcher
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(protocolMatcher(it)))

proc getPeersByDirection*(peerStore: PeerStore, direction: PeerDirection): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.direction == direction)

proc getNotConnectedPeers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness != Connected)

proc getConnectedPeers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness == Connected)

proc getPeersByProtocol*(peerStore: PeerStore, proto: string): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.protocols.contains(proto))

proc getReachablePeers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness == CanConnect or it.connectedness == Connected)
