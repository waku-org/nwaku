{.push raises: [Defect].}

import
  std/[tables, sequtils, sets],
  libp2p/builders,
  libp2p/peerstore

export peerstore, builders

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
  
  ConnectionBook* = object of PeerBook[Connectedness]

  DisconnectBook* = object of PeerBook[int64] # Keeps track of when peers were disconnected in Unix timestamps

  WakuPeerStore* = ref object
    addressBook*: AddressBook
    protoBook*: ProtoBook
    keyBook*: KeyBook
    connectionBook*: ConnectionBook
    disconnectBook*: DisconnectBook
  
  StoredInfo* = object
    # Collates stored info about a peer
    peerId*: PeerID
    addrs*: HashSet[MultiAddress]
    protos*: HashSet[string]
    publicKey*: PublicKey

proc new*(T: type WakuPeerStore): WakuPeerStore =
  var p: WakuPeerStore
  new(p)
  return p

##################  
# Peer Store API #
##################

proc get*(peerStore: WakuPeerStore,
          peerId: PeerID): StoredInfo =
  ## Get the stored information of a given peer.
  
  StoredInfo(
    peerId: peerId,
    addrs: peerStore.addressBook.get(peerId),
    protos: peerStore.protoBook.get(peerId),
    publicKey: peerStore.keyBook.get(peerId)
  )

proc peers*(peerStore: WakuPeerStore): seq[StoredInfo] =
  ## Get all the stored information of every peer.
  
  let allKeys = concat(toSeq(keys(peerStore.addressBook.book)),
                       toSeq(keys(peerStore.protoBook.book)),
                       toSeq(keys(peerStore.keyBook.book))).toHashSet()

  return allKeys.mapIt(peerStore.get(it))
