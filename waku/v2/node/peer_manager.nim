{.push raises: [Defect, Exception].}

import
  std/[options, sets, sequtils],
  chronos, chronicles, metrics,
  libp2p/standard_setup,
  libp2p/peerstore

export peerstore, standard_setup

declareCounter waku_peers_dials, "Number of peer dials", ["outcome"]

logScope:
  topics = "wakupeers"

type
  PeerManager* = ref object of RootObj
    switch*: Switch
    peerStore*: PeerStore

const
  defaultDialTimeout = 1.minutes # @TODO should this be made configurable?

proc new*(T: type PeerManager, switch: Switch): PeerManager =
  T(switch: switch,
    peerStore: PeerStore.new())

####################
# Helper functions #
####################

proc toPeerInfo(storedInfo: StoredInfo): PeerInfo =
  PeerInfo.init(peerId = storedInfo.peerId,
                addrs = toSeq(storedInfo.addrs),
                protocols = toSeq(storedInfo.protos))

#####################
# Manager interface #
#####################

proc peers*(pm: PeerManager): seq[StoredInfo] =
  # Return the known info for all peers
  pm.peerStore.peers()

proc peers*(pm: PeerManager, proto: string): seq[StoredInfo] =
  # Return the known info for all peers registered on the specified protocol
  pm.peers.filterIt(it.protos.contains(proto))

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

proc hasPeer*(pm: PeerManager, peerInfo: PeerInfo, proto: string): bool =
  # Returns `true` if peer is included in manager for the specified protocol

  pm.peerStore.get(peerInfo.peerId).protos.contains(proto)

proc addPeer*(pm: PeerManager, peerInfo: PeerInfo, proto: string) =
  # Adds peer to manager for the specified protocol

  debug "Adding peer to manager", peerId = peerInfo.peerId, addr = peerInfo.addrs[0], proto = proto
  
  # ...known addresses
  for multiaddr in peerInfo.addrs:
    pm.peerStore.addressBook.add(peerInfo.peerId, multiaddr)
  
  # ...public key
  var publicKey: PublicKey
  discard peerInfo.peerId.extractPublicKey(publicKey)

  pm.peerStore.keyBook.set(peerInfo.peerId, publicKey)

  # ...associated protocols
  pm.peerStore.protoBook.add(peerInfo.peerId, proto)

proc selectPeer*(pm: PeerManager, proto: string): Option[PeerInfo] =
  # Selects the best peer for a given protocol
  let peers = pm.peers.filterIt(it.protos.contains(proto))

  if peers.len >= 1:
     # @TODO proper heuristic here that compares peer scores and selects "best" one. For now the first peer for the given protocol is returned
    let peerStored = peers[0]

    return some(peerStored.toPeerInfo())
  else:
    return none(PeerInfo)

####################
# Dialer interface #
####################

proc dialPeer*(pm: PeerManager, peerInfo: PeerInfo, proto: string, dialTimeout = defaultDialTimeout): Future[Option[Connection]] {.async.} =
  # Dial a given peer and add it to the list of known peers
  # @TODO check peer validity and score before continuing. Limit number of peers to be managed.
  
  # First add dialed peer info to peer store, if it does not exist yet...
  if not pm.hasPeer(peerInfo, proto):
    trace "Adding newly dialed peer to manager", peerId = peerInfo.peerId, addr = peerInfo.addrs[0], proto = proto
    pm.addPeer(peerInfo, proto)

  info "Dialing peer from manager", wireAddr = peerInfo.addrs[0], peerId = peerInfo.peerId

  # Dial Peer
  # @TODO Keep track of conn and connected state in peer store
  let dialFut = pm.switch.dial(peerInfo.peerId, peerInfo.addrs, proto)

  try:
    # Attempt to dial remote peer
    if (await dialFut.withTimeout(dialTimeout)):
      waku_peers_dials.inc(labelValues = ["successful"])
      return some(dialFut.read())
    else:
      # @TODO any redial attempts?
      # @TODO indicate CannotConnect on peer metadata
      debug "Dialing remote peer timed out"
      waku_peers_dials.inc(labelValues = ["timeout"])
      return none(Connection)
  except CatchableError as e:
    # @TODO any redial attempts?
    # @TODO indicate CannotConnect on peer metadata
    debug "Dialing remote peer failed", msg = e.msg
    waku_peers_dials.inc(labelValues = ["failed"])
    return none(Connection)
