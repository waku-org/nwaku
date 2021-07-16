{.push raises: [Defect].}

import
  std/[options, sets, sequtils, times],
  chronos, chronicles, metrics,
  ./waku_peer_store,
  ../storage/peer/peer_storage

export waku_peer_store, peer_storage

declareCounter waku_peers_dials, "Number of peer dials", ["outcome"]
declarePublicGauge waku_peers_errors, "Number of peer manager errors", ["type"]

logScope:
  topics = "wakupeers"

type
  PeerManager* = ref object of RootObj
    switch*: Switch
    peerStore*: WakuPeerStore
    storage: PeerStorage

let
  defaultDialTimeout = chronos.minutes(1) # @TODO should this be made configurable?

####################
# Helper functions #
####################

proc toPeerInfo*(storedInfo: StoredInfo): PeerInfo =
  PeerInfo.init(peerId = storedInfo.peerId,
                addrs = toSeq(storedInfo.addrs),
                protocols = toSeq(storedInfo.protos))

proc insertOrReplace(ps: PeerStorage,
                     peerId: PeerID,
                     storedInfo: StoredInfo,
                     connectedness: Connectedness,
                     disconnectTime: int64 = 0) =
  # Insert peer entry into persistent storage, or replace existing entry with updated info
  let res = ps.put(peerId, storedInfo, connectedness, disconnectTime)
  if res.isErr:
    warn "failed to store peers", err = res.error
    waku_peers_errors.inc(labelValues = ["storage_failure"])

proc dialPeer(pm: PeerManager, peerId: PeerID, 
              addrs: seq[MultiAddress], proto: string,
              dialTimeout = defaultDialTimeout): Future[Option[Connection]] {.async.} =
  info "Dialing peer from manager", wireAddr = addrs[0], peerId = peerId

  # Dial Peer
  let dialFut = pm.switch.dial(peerId, addrs, proto)

  try:
    # Attempt to dial remote peer
    if (await dialFut.withTimeout(dialTimeout)):
      waku_peers_dials.inc(labelValues = ["successful"])
      return some(dialFut.read())
    else:
      # @TODO any redial attempts?
      debug "Dialing remote peer timed out"
      waku_peers_dials.inc(labelValues = ["timeout"])

      pm.peerStore.connectionBook.set(peerId, CannotConnect)
      if not pm.storage.isNil:
        pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CannotConnect)
      
      return none(Connection)
  except CatchableError as e:
    # @TODO any redial attempts?
    debug "Dialing remote peer failed", msg = e.msg
    waku_peers_dials.inc(labelValues = ["failed"])
    
    pm.peerStore.connectionBook.set(peerId, CannotConnect)
    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CannotConnect)
    
    return none(Connection)

proc loadFromStorage(pm: PeerManager) =
  # Load peers from storage, if available
  proc onData(peerId: PeerID, storedInfo: StoredInfo, connectedness: Connectedness, disconnectTime: int64) =
    if peerId == pm.switch.peerInfo.peerId:
      # Do not manage self
      return

    pm.peerStore.addressBook.set(peerId, storedInfo.addrs)
    pm.peerStore.protoBook.set(peerId, storedInfo.protos)
    pm.peerStore.keyBook.set(peerId, storedInfo.publicKey)
    pm.peerStore.connectionBook.set(peerId, NotConnected)  # Reset connectedness state
    pm.peerStore.disconnectBook.set(peerId, disconnectTime)
  
  let res = pm.storage.getAll(onData)
  if res.isErr:
    warn "failed to load peers from storage", err = res.error
    waku_peers_errors.inc(labelValues = ["storage_load_failure"])
  
##################
# Initialisation #
##################   

proc onConnEvent(pm: PeerManager, peerId: PeerID, event: ConnEvent) {.async.} =
  case event.kind
  of ConnEventKind.Connected:
    pm.peerStore.connectionBook.set(peerId, Connected)
    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), Connected)
    return
  of ConnEventKind.Disconnected:
    pm.peerStore.connectionBook.set(peerId, CanConnect)
    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CanConnect, getTime().toUnix)
    return

proc new*(T: type PeerManager, switch: Switch, storage: PeerStorage = nil): PeerManager =
  let pm = PeerManager(switch: switch,
                       peerStore: WakuPeerStore.new(),
                       storage: storage)

  proc peerHook(peerInfo: PeerInfo, event: ConnEvent): Future[void] {.gcsafe.} =
    onConnEvent(pm, peerInfo.peerId, event)
  
  pm.switch.addConnEventHandler(peerHook, ConnEventKind.Connected)
  pm.switch.addConnEventHandler(peerHook, ConnEventKind.Disconnected)

  if not storage.isNil:
    pm.loadFromStorage() # Load previously managed peers.
    
  return pm

#####################
# Manager interface #
#####################

proc peers*(pm: PeerManager): seq[StoredInfo] =
  # Return the known info for all peers
  pm.peerStore.peers()

proc peers*(pm: PeerManager, proto: string): seq[StoredInfo] =
  # Return the known info for all peers registered on the specified protocol
  pm.peers.filterIt(it.protos.contains(proto))

proc connectedness*(pm: PeerManager, peerId: PeerId): Connectedness =
  # Return the connection state of the given, managed peer
  # @TODO the PeerManager should keep and update local connectedness state for peers, redial on disconnect, etc.
  # @TODO richer return than just bool, e.g. add enum "CanConnect", "CannotConnect", etc. based on recent connection attempts

  let storedInfo = pm.peerStore.get(peerId)

  if (storedInfo == StoredInfo()):
    # Peer is not managed, therefore not connected
    return NotConnected
  else:
    pm.peerStore.connectionBook.get(peerId)

proc hasPeer*(pm: PeerManager, peerInfo: PeerInfo, proto: string): bool =
  # Returns `true` if peer is included in manager for the specified protocol

  pm.peerStore.get(peerInfo.peerId).protos.contains(proto)

proc hasPeers*(pm: PeerManager, proto: string): bool =
  # Returns `true` if manager has any peers for the specified protocol
  pm.peers.anyIt(it.protos.contains(proto))

proc addPeer*(pm: PeerManager, peerInfo: PeerInfo, proto: string) =
  # Adds peer to manager for the specified protocol

  if peerInfo.peerId == pm.switch.peerInfo.peerId:
    # Do not attempt to manage our unmanageable self
    return
  
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

  # Add peer to storage. Entry will subsequently be updated with connectedness information
  if not pm.storage.isNil:
    pm.storage.insertOrReplace(peerInfo.peerId, pm.peerStore.get(peerInfo.peerId), NotConnected)

proc selectPeer*(pm: PeerManager, proto: string): Option[PeerInfo] =
  # Selects the best peer for a given protocol
  let peers = pm.peers.filterIt(it.protos.contains(proto))

  if peers.len >= 1:
     # @TODO proper heuristic here that compares peer scores and selects "best" one. For now the first peer for the given protocol is returned
    let peerStored = peers[0]

    return some(peerStored.toPeerInfo())
  else:
    return none(PeerInfo)

proc reconnectPeers*(pm: PeerManager, proto: string, backoff: chronos.Duration = chronos.seconds(0)) {.async.} =
  ## Reconnect to peers registered for this protocol. This will update connectedness.
  ## Especially useful to resume connections from persistent storage after a restart.
  
  debug "Reconnecting peers", proto=proto
  
  for storedInfo in pm.peers(proto):
    # Check if peer is reachable.
    if pm.peerStore.connectionBook.get(storedInfo.peerId) == CannotConnect:
      debug "Not reconnecting to unreachable peer", peerId=storedInfo.peerId
      continue
    
    # Respect optional backoff period where applicable.
    let
      disconnectTime = Moment.init(pm.peerStore.disconnectBook.get(storedInfo.peerId), Second)  # Convert 
      currentTime = Moment.init(getTime().toUnix, Second) # Current time comparable to persisted value
      backoffTime = disconnectTime + backoff - currentTime # Consider time elapsed since last disconnect
    
    trace "Respecting backoff", backoff=backoff, disconnectTime=disconnectTime, currentTime=currentTime, backoffTime=backoffTime
    
    if backoffTime > ZeroDuration:
      debug "Backing off before reconnect...", peerId=storedInfo.peerId, backoffTime=backoffTime
      # We disconnected recently and still need to wait for a backoff period before connecting
      await sleepAsync(backoffTime)

    trace "Reconnecting to peer", peerId=storedInfo.peerId
    discard await pm.dialPeer(storedInfo.peerId, toSeq(storedInfo.addrs), proto)

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
  
  if peerInfo.peerId == pm.switch.peerInfo.peerId:
    # Do not attempt to dial self
    return none(Connection)

  return await pm.dialPeer(peerInfo.peerId, peerInfo.addrs, proto, dialTimeout)
