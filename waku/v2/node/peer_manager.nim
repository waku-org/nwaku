{.push raises: [Defect, Exception].}

import
  chronos, chronicles,
  libp2p/standard_setup,
  libp2p/peerstore

type
  PeerManager* = ref object of RootObj
    switch*: Switch
    peerStore*: PeerStore

proc new*(T: type PeerManager, switch: Switch): PeerManager =
  T(switch: switch,
    peerStore: PeerStore.new())

####################
# Dialer interface #
####################

proc dialPeer*(pm: PeerManager, peerInfo: PeerInfo, proto: string): Future[Connection] {.async.} =
  # Dial a given peer and add it to the list of known peers
  # @TODO check peer validity, duplicates and score before continuing. Limit number of peers to be managed.
  
  # First add dialed peer info to peer store...

  debug "Adding dialed peer to manager", peerId = peerInfo.peerId, addr = peerInfo.addrs[0], proto = proto
  
  # ...known addresses
  for multiaddr in peerInfo.addrs:
    pm.peerStore.addressBook.add(peerInfo.peerId, multiaddr)
  
  # ...public key
  var publicKey: PublicKey
  discard peerInfo.peerId.extractPublicKey(publicKey)

  pm.peerStore.keyBook.set(peerInfo.peerId, publicKey)

  # ...associated protocols
  pm.peerStore.protoBook.add(peerInfo.peerId, proto)

  info "Dialing peer from manager", wireAddr = peerInfo.addrs[0], peerId = peerInfo.peerId

  # Dial Peer
  # @TODO Keep track of conn and connected state in peer store
  return await pm.switch.dial(peerInfo.peerId, peerInfo.addrs, proto)

#####################
# Manager interface #
#####################

proc peers*(pm: PeerManager): seq[StoredInfo] =
  # Return the known info for all peers
  pm.peerStore.peers()

proc connectedness*(pm: PeerManager, peerId: PeerId): bool =
  # Return the connection state of the given, managed peer
  # @TODO the PeerManager should keep and update local connectedness state for peers, redial on disconnect, etc.
  # @TODO richer return than just bool, e.g. add enum "CanConnect", "CannotConnect", etc. based on recent connection attempts

  let storedInfo = pm.peerStore.get(peerId)

  if (storedInfo == StoredInfo()):
    # Peer is not managed, therefore not connected
    return false
  else:
    pm.switch.isConnected(peerId)
