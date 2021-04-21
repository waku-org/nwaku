{.push raises: [Defect].}

import
  libp2p/standard_setup,
  libp2p/peerstore

export peerstore, standard_setup

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

  WakuPeerStore* = ref object of PeerStore
    connectionBook*: ConnectionBook
    disconnectBook*: DisconnectBook

proc new*(T: type WakuPeerStore): WakuPeerStore =
  var p: WakuPeerStore
  new(p)
  return p