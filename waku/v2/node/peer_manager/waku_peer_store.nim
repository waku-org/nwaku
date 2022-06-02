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
  
  ConnectionBook* = ref object of PeerBook[Connectedness]

  DisconnectBook* = ref object of PeerBook[int64] # Keeps track of when peers were disconnected in Unix timestamps

  WakuPeerStore* = ref object
    addressBook*: AddressBook
    protoBook*: ProtoBook
    keyBook*: KeyBook
    connectionBook*: ConnectionBook
    disconnectBook*: DisconnectBook
  
  StoredInfo* = object
    # Collates stored info about a peer
    peerId*: PeerID
    addrs*: seq[MultiAddress]
    protos*: seq[string]
    publicKey*: PublicKey

proc new*(T: type WakuPeerStore): WakuPeerStore =
  let
    addressBook = AddressBook(book: initTable[PeerID, seq[MultiAddress]]())
    protoBook = ProtoBook(book: initTable[PeerID, seq[string]]())
    keyBook = KeyBook(book: initTable[PeerID, PublicKey]())
    connectionBook = ConnectionBook(book: initTable[PeerID, Connectedness]())
    disconnectBook = DisconnectBook(book: initTable[PeerID, int64]())
  
  T(addressBook: addressBook,
    protoBook: protoBook,
    keyBook: keyBook,
    connectionBook: connectionBook,
    disconnectBook: disconnectBook)  

#####################
# Utility functions #
#####################

proc add*[T](peerBook: SeqPeerBook[T],
             peerId: PeerId,
             entry: T) =
  ## Add entry to a given peer. If the peer is not known,
  ## it will be set with the provided entry.
  
  peerBook.book.mgetOrPut(peerId,
                          newSeq[T]()).add(entry)
  
  # TODO: Notify clients?

##################  
# Peer Store API #
##################

proc get*(peerStore: WakuPeerStore,
          peerId: PeerID): StoredInfo =
  ## Get the stored information of a given peer.
  
  StoredInfo(
    peerId: peerId,
    addrs: peerStore.addressBook[peerId],
    protos: peerStore.protoBook[peerId],
    publicKey: peerStore.keyBook[peerId]
  )

proc peers*(peerStore: WakuPeerStore): seq[StoredInfo] =
  ## Get all the stored information of every peer.
  
  let allKeys = concat(toSeq(keys(peerStore.addressBook.book)),
                       toSeq(keys(peerStore.protoBook.book)),
                       toSeq(keys(peerStore.keyBook.book))).toHashSet()

  return allKeys.mapIt(peerStore.get(it))
