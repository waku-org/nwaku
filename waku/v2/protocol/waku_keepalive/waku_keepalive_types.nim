import
  bearssl,
  libp2p/protocols/protocol,
  ../../node/peer_manager/peer_manager

type
  KeepaliveMessage* = object
    # Currently no fields for a keepalive message

  WakuKeepalive* = ref object of LPProtocol
    rng*: ref BrHmacDrbgContext
    peerManager*: PeerManager
