when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/[options, sets, sequtils, times],
  chronos,
  chronicles,
  metrics,
  libp2p/multistream
import
  ../../utils/peers,
  ./peer_store/peer_storage,
  ./waku_peer_store

export waku_peer_store, peer_storage, peers


declareCounter waku_peers_dials, "Number of peer dials", ["outcome"]
declarePublicCounter waku_node_conns_initiated, "Number of connections initiated", ["source"]
declarePublicGauge waku_peers_errors, "Number of peer manager errors", ["type"]


logScope:
  topics = "waku node peer_manager"

type
  PeerManager* = ref object of RootObj
    switch*: Switch
    peerStore*: PeerStore
    storage: PeerStorage

let
  defaultDialTimeout = chronos.minutes(1) # TODO: should this be made configurable?

####################
# Helper functions #
####################

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
  info "Dialing peer from manager", wireAddr = addrs, peerId = peerId

  # Dial Peer
  let dialFut = pm.switch.dial(peerId, addrs, proto)

  try:
    # Attempt to dial remote peer
    if (await dialFut.withTimeout(dialTimeout)):
      waku_peers_dials.inc(labelValues = ["successful"])
      return some(dialFut.read())
    else:
      # TODO: any redial attempts?
      debug "Dialing remote peer timed out"
      waku_peers_dials.inc(labelValues = ["timeout"])

      pm.peerStore[ConnectionBook][peerId] = CannotConnect
      if not pm.storage.isNil:
        pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CannotConnect)

      return none(Connection)
  except CatchableError as e:
    # TODO: any redial attempts?
    debug "Dialing remote peer failed", msg = e.msg
    waku_peers_dials.inc(labelValues = ["failed"])

    pm.peerStore[ConnectionBook][peerId] = CannotConnect
    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CannotConnect)

    return none(Connection)

proc loadFromStorage(pm: PeerManager) =
  debug "loading peers from storage"
  # Load peers from storage, if available
  proc onData(peerId: PeerID, storedInfo: StoredInfo, connectedness: Connectedness, disconnectTime: int64) =
    trace "loading peer", peerId=peerId, storedInfo=storedInfo, connectedness=connectedness

    if peerId == pm.switch.peerInfo.peerId:
      # Do not manage self
      return

    # nim-libp2p books
    pm.peerStore[AddressBook][peerId] = storedInfo.addrs
    pm.peerStore[ProtoBook][peerId] = storedInfo.protos
    pm.peerStore[KeyBook][peerId] = storedInfo.publicKey
    pm.peerStore[AgentBook][peerId] = storedInfo.agent
    pm.peerStore[ProtoVersionBook][peerId] = storedInfo.protoVersion

    # custom books
    pm.peerStore[ConnectionBook][peerId] = NotConnected  # Reset connectedness state
    pm.peerStore[DisconnectBook][peerId] = disconnectTime
    pm.peerStore[SourceBook][peerId] = storedInfo.origin

  let res = pm.storage.getAll(onData)
  if res.isErr:
    warn "failed to load peers from storage", err = res.error
    waku_peers_errors.inc(labelValues = ["storage_load_failure"])
  else:
    debug "successfully queried peer storage"

##################
# Initialisation #
##################

proc onConnEvent(pm: PeerManager, peerId: PeerID, event: ConnEvent) {.async.} =
  if not pm.peerStore[AddressBook].contains(peerId):
    ## We only consider connection events if we
    ## already track some addresses for this peer
    return

  case event.kind
  of ConnEventKind.Connected:
    pm.peerStore[ConnectionBook][peerId] = Connected
    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), Connected)
    return
  of ConnEventKind.Disconnected:
    pm.peerStore[ConnectionBook][peerId] = CanConnect
    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CanConnect, getTime().toUnix)
    return

proc new*(T: type PeerManager, switch: Switch, storage: PeerStorage = nil): PeerManager =
  let pm = PeerManager(switch: switch,
                       peerStore: switch.peerStore,
                       storage: storage)

  proc peerHook(peerId: PeerID, event: ConnEvent): Future[void] {.gcsafe.} =
    onConnEvent(pm, peerId, event)

  pm.switch.addConnEventHandler(peerHook, ConnEventKind.Connected)
  pm.switch.addConnEventHandler(peerHook, ConnEventKind.Disconnected)

  if not storage.isNil():
    debug "found persistent peer storage"
    pm.loadFromStorage() # Load previously managed peers.
  else:
    debug "no peer storage found"

  return pm

#####################
# Manager interface #
#####################

proc addPeer*(pm: PeerManager, remotePeerInfo: RemotePeerInfo, proto: string) =
  # Adds peer to manager for the specified protocol

  if remotePeerInfo.peerId == pm.switch.peerInfo.peerId:
    # Do not attempt to manage our unmanageable self
    return

  debug "Adding peer to manager", peerId = remotePeerInfo.peerId, addr = remotePeerInfo.addrs[0], proto = proto

  # ...known addresses
  for multiaddr in remotePeerInfo.addrs:
    pm.peerStore[AddressBook][remotePeerInfo.peerId] = pm.peerStore[AddressBook][remotePeerInfo.peerId] & multiaddr

  # ...public key
  var publicKey: PublicKey
  discard remotePeerInfo.peerId.extractPublicKey(publicKey)

  pm.peerStore[KeyBook][remotePeerInfo.peerId] = publicKey

  # nim-libp2p identify overrides this
  pm.peerStore[ProtoBook][remotePeerInfo.peerId] = pm.peerStore[ProtoBook][remotePeerInfo.peerId] & proto

  # Add peer to storage. Entry will subsequently be updated with connectedness information
  if not pm.storage.isNil:
    pm.storage.insertOrReplace(remotePeerInfo.peerId, pm.peerStore.get(remotePeerInfo.peerId), NotConnected)

proc reconnectPeers*(pm: PeerManager,
                     proto: string,
                     protocolMatcher: Matcher,
                     backoff: chronos.Duration = chronos.seconds(0)) {.async.} =
  ## Reconnect to peers registered for this protocol. This will update connectedness.
  ## Especially useful to resume connections from persistent storage after a restart.

  debug "Reconnecting peers", proto=proto

  for storedInfo in pm.peerStore.peers(protocolMatcher):
    # Check that the peer can be connected
    if storedInfo.connectedness == CannotConnect:
      debug "Not reconnecting to unreachable or non-existing peer", peerId=storedInfo.peerId
      continue

    # Respect optional backoff period where applicable.
    let
      # TODO: Add method to peerStore (eg isBackoffExpired())
      disconnectTime = Moment.init(storedInfo.disconnectTime, Second)  # Convert
      currentTime = Moment.init(getTime().toUnix, Second) # Current time comparable to persisted value
      backoffTime = disconnectTime + backoff - currentTime # Consider time elapsed since last disconnect

    trace "Respecting backoff", backoff=backoff, disconnectTime=disconnectTime, currentTime=currentTime, backoffTime=backoffTime

    # TODO: This blocks the whole function. Try to connect to another peer in the meantime.
    if backoffTime > ZeroDuration:
      debug "Backing off before reconnect...", peerId=storedInfo.peerId, backoffTime=backoffTime
      # We disconnected recently and still need to wait for a backoff period before connecting
      await sleepAsync(backoffTime)

    trace "Reconnecting to peer", peerId=storedInfo.peerId
    discard await pm.dialPeer(storedInfo.peerId, toSeq(storedInfo.addrs), proto)

####################
# Dialer interface #
####################

proc dialPeer*(pm: PeerManager, remotePeerInfo: RemotePeerInfo, proto: string, dialTimeout = defaultDialTimeout): Future[Option[Connection]] {.async.} =
  # Dial a given peer and add it to the list of known peers
  # TODO: check peer validity and score before continuing. Limit number of peers to be managed.

  # First add dialed peer info to peer store, if it does not exist yet...
  if not pm.peerStore.hasPeer(remotePeerInfo.peerId, proto):
    trace "Adding newly dialed peer to manager", peerId = remotePeerInfo.peerId, addr = remotePeerInfo.addrs[0], proto = proto
    pm.addPeer(remotePeerInfo, proto)

  if remotePeerInfo.peerId == pm.switch.peerInfo.peerId:
    # Do not attempt to dial self
    return none(Connection)

  return await pm.dialPeer(remotePeerInfo.peerId, remotePeerInfo.addrs, proto, dialTimeout)

proc dialPeer*(pm: PeerManager, peerId: PeerID, proto: string, dialTimeout = defaultDialTimeout): Future[Option[Connection]] {.async.} =
  # Dial an existing peer by looking up it's existing addrs in the switch's peerStore
  # TODO: check peer validity and score before continuing. Limit number of peers to be managed.

  if peerId == pm.switch.peerInfo.peerId:
    # Do not attempt to dial self
    return none(Connection)

  let addrs = pm.switch.peerStore[AddressBook][peerId]

  return await pm.dialPeer(peerId, addrs, proto, dialTimeout)

proc connectToNode(pm: PeerManager, remotePeer: RemotePeerInfo, proto: string, source = "api") {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  info "Connecting to node", remotePeer = remotePeer, source = source

  info "Attempting dial", wireAddr = remotePeer.addrs[0], peerId = remotePeer.peerId
  let connOpt = await pm.dialPeer(remotePeer, proto)

  if connOpt.isSome():
    info "Successfully connected to peer", wireAddr = remotePeer.addrs[0], peerId = remotePeer.peerId
    waku_node_conns_initiated.inc(labelValues = [source])
  else:
    error "Failed to connect to peer", wireAddr = remotePeer.addrs[0], peerId = remotePeer.peerId
    waku_peers_errors.inc(labelValues = ["conn_init_failure"])

proc connectToNodes*(pm: PeerManager, nodes: seq[string], proto: string, source = "api") {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  info "connectToNodes", len = nodes.len

  for nodeId in nodes:
    await connectToNode(pm, parseRemotePeerInfo(nodeId), proto ,source)

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(chronos.seconds(5))

proc connectToNodes*(pm: PeerManager, nodes: seq[RemotePeerInfo], proto: string, source = "api") {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  info "connectToNodes", len = nodes.len

  for remotePeerInfo in nodes:
    await connectToNode(pm, remotePeerInfo, proto, source)

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(chronos.seconds(5))

