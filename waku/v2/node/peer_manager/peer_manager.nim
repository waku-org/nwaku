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
  ../../waku/v2/protocol/waku_relay,
  ./peer_store/peer_storage,
  ./waku_peer_store

export waku_peer_store, peer_storage, peers

declareCounter waku_peers_dials, "Number of peer dials", ["outcome"]
# TODO: Populate from PeerStore.Source when ready
declarePublicCounter waku_node_conns_initiated, "Number of connections initiated", ["source"]
declarePublicGauge waku_peers_errors, "Number of peer manager errors", ["type"]
declarePublicGauge waku_connected_peers, "Number of connected peers per direction: inbound|outbound", ["direction"]
declarePublicGauge waku_peer_store_size, "Number of peers managed by the peer store"

logScope:
  topics = "waku node peer_manager"

const
  # TODO: Make configurable
  DefaultDialTimeout = chronos.seconds(10)

  # Max attempts before removing the peer
  MaxFailedAttempts = 5

  # Time to wait before attempting to dial again is calculated as:
  # initialBackoffInSec*(backoffFactor^(failedAttempts-1))
  # 120s, 480s, 1920, 7680s
  InitialBackoffInSec = 120
  BackoffFactor = 4

  # Limit the amount of paralel dials
  MaxParalelDials = 10

  # Delay between consecutive relayConnectivityLoop runs
  ConnectivityLoopInterval = chronos.seconds(30)

  # How often the peer store is pruned
  PrunePeerStoreInterval = chronos.minutes(5)

type
  PeerManager* = ref object of RootObj
    switch*: Switch
    peerStore*: PeerStore
    initialBackoffInSec*: int
    backoffFactor*: int
    maxFailedAttempts*: int
    storage: PeerStorage
    serviceSlots*: Table[string, RemotePeerInfo]
    started: bool

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
              dialTimeout = DefaultDialTimeout,
              source = "api",
              ): Future[Option[Connection]] {.async.} =

  # Do not attempt to dial self
  if peerId == pm.switch.peerInfo.peerId:
    return none(Connection)

  let failedAttempts = pm.peerStore[NumberFailedConnBook][peerId]
  debug "Dialing peer", wireAddr = addrs, peerId = peerId, failedAttempts=failedAttempts

  # Dial Peer
  let dialFut = pm.switch.dial(peerId, addrs, proto)

  var reasonFailed = ""
  try:
    if (await dialFut.withTimeout(dialTimeout)):
      waku_peers_dials.inc(labelValues = ["successful"])
      # TODO: This will be populated from the peerstore info when ready
      waku_node_conns_initiated.inc(labelValues = [source])
      pm.peerStore[NumberFailedConnBook][peerId] = 0
      return some(dialFut.read())
    else:
      reasonFailed = "timeout"
      await cancelAndWait(dialFut)
  except CatchableError as exc:
    reasonFailed = "failed"

  # Dial failed
  pm.peerStore[NumberFailedConnBook][peerId] = pm.peerStore[NumberFailedConnBook][peerId] + 1
  pm.peerStore[LastFailedConnBook][peerId] = Moment.init(getTime().toUnix, Second)
  pm.peerStore[ConnectionBook][peerId] = CannotConnect

  debug "Dialing peer failed",
          peerId = peerId,
          reason = reasonFailed,
          failedAttempts = pm.peerStore[NumberFailedConnBook][peerId]
  waku_peers_dials.inc(labelValues = [reasonFailed])

  # Update storage
  if not pm.storage.isNil:
    pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CannotConnect)

  return none(Connection)

proc loadFromStorage(pm: PeerManager) =
  debug "loading peers from storage"
  # Load peers from storage, if available
  proc onData(peerId: PeerID, storedInfo: StoredInfo, connectedness: Connectedness, disconnectTime: int64) =
    trace "loading peer", peerId= $peerId, storedInfo= $storedInfo, connectedness=connectedness

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

  case event.kind
  of ConnEventKind.Connected:
    let direction = if event.incoming: Inbound else: Outbound
    pm.peerStore[ConnectionBook][peerId] = Connected
    pm.peerStore[DirectionBook][peerId] = direction

    waku_connected_peers.inc(1, labelValues=[$direction])

    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), Connected)
    return
  of ConnEventKind.Disconnected:
    waku_connected_peers.dec(1, labelValues=[$pm.peerStore[DirectionBook][peerId]])

    pm.peerStore[DirectionBook][peerId] = UnknownDirection
    pm.peerStore[ConnectionBook][peerId] = CanConnect
    if not pm.storage.isNil:
      pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), CanConnect, getTime().toUnix)
    return

proc new*(T: type PeerManager,
          switch: Switch,
          storage: PeerStorage = nil,
          initialBackoffInSec = InitialBackoffInSec,
          backoffFactor = BackoffFactor,
          maxFailedAttempts = MaxFailedAttempts,): PeerManager =

  let capacity = switch.peerStore.capacity
  let maxConnections = switch.connManager.inSema.size
  if maxConnections > capacity:
    error "Max number of connections can't be greater than PeerManager capacity",
         capacity = capacity,
         maxConnections = maxConnections
    raise newException(Defect, "Max number of connections can't be greater than PeerManager capacity")

  let pm = PeerManager(switch: switch,
                       peerStore: switch.peerStore,
                       storage: storage,
                       initialBackoffInSec: initialBackoffInSec,
                       backoffFactor: backoffFactor,
                       maxFailedAttempts: maxFailedAttempts)
  proc peerHook(peerId: PeerID, event: ConnEvent): Future[void] {.gcsafe.} =
    onConnEvent(pm, peerId, event)

  proc peerStoreChanged(peerId: PeerId) {.gcsafe.} =
    waku_peer_store_size.set(toSeq(pm.peerStore[AddressBook].book.keys).len.int64)

  pm.switch.addConnEventHandler(peerHook, ConnEventKind.Connected)
  pm.switch.addConnEventHandler(peerHook, ConnEventKind.Disconnected)

  # called every time the peerstore is updated
  pm.peerStore[AddressBook].addHandler(peerStoreChanged)

  pm.serviceSlots = initTable[string, RemotePeerInfo]()

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

  # ...public key
  var publicKey: PublicKey
  discard remotePeerInfo.peerId.extractPublicKey(publicKey)

  if pm.peerStore[AddressBook][remotePeerInfo.peerId] == remotePeerInfo.addrs and
     pm.peerStore[KeyBook][remotePeerInfo.peerId] == publicKey:
    # Peer already managed
    return

  debug "Adding peer to manager", peerId = remotePeerInfo.peerId, addresses = remotePeerInfo.addrs, proto = proto

  pm.peerStore[AddressBook][remotePeerInfo.peerId] = remotePeerInfo.addrs
  pm.peerStore[KeyBook][remotePeerInfo.peerId] = publicKey

  # TODO: Remove this once service slots is ready
  pm.peerStore[ProtoBook][remotePeerInfo.peerId] = pm.peerStore[ProtoBook][remotePeerInfo.peerId] & proto

  # Add peer to storage. Entry will subsequently be updated with connectedness information
  if not pm.storage.isNil:
    pm.storage.insertOrReplace(remotePeerInfo.peerId, pm.peerStore.get(remotePeerInfo.peerId), NotConnected)

proc addServicePeer*(pm: PeerManager, remotePeerInfo: RemotePeerInfo, proto: string) =
  # Do not add relay peers
  if proto == WakuRelayCodec:
    warn "Can't add relay peer to service peers slots"
    return

  info "Adding peer to service slots", peerId = remotePeerInfo.peerId, addr = remotePeerInfo.addrs[0], service = proto

   # Set peer for service slot
  pm.serviceSlots[proto] = remotePeerInfo

  # TODO: Remove proto once fully refactored
  pm.addPeer(remotePeerInfo, proto)

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

    trace "Reconnecting to peer", peerId= $storedInfo.peerId
    discard await pm.dialPeer(storedInfo.peerId, toSeq(storedInfo.addrs), proto)

####################
# Dialer interface #
####################

proc dialPeer*(pm: PeerManager,
               remotePeerInfo: RemotePeerInfo,
               proto: string,
               dialTimeout = DefaultDialTimeout,
               source = "api",
               ): Future[Option[Connection]] {.async.} =
  # Dial a given peer and add it to the list of known peers
  # TODO: check peer validity and score before continuing. Limit number of peers to be managed.

  # First add dialed peer info to peer store, if it does not exist yet...
  if not pm.peerStore.hasPeer(remotePeerInfo.peerId, proto):
    trace "Adding newly dialed peer to manager", peerId= $remotePeerInfo.peerId, address= $remotePeerInfo.addrs[0], proto= proto
    pm.addPeer(remotePeerInfo, proto)

  return await pm.dialPeer(remotePeerInfo.peerId,remotePeerInfo.addrs, proto, dialTimeout, source)

proc dialPeer*(pm: PeerManager,
               peerId: PeerID,
               proto: string,
               dialTimeout = DefaultDialTimeout,
               source = "api",
               ): Future[Option[Connection]] {.async.} =
  # Dial an existing peer by looking up it's existing addrs in the switch's peerStore
  # TODO: check peer validity and score before continuing. Limit number of peers to be managed.

  let addrs = pm.switch.peerStore[AddressBook][peerId]
  return await pm.dialPeer(peerId, addrs, proto, dialTimeout, source)

proc connectToNodes*(pm: PeerManager,
                     nodes: seq[string]|seq[RemotePeerInfo],
                     proto: string,
                     dialTimeout = DefaultDialTimeout,
                     source = "api") {.async.} =
  if nodes.len == 0:
    return

  info "Dialing multiple peers", numOfPeers = nodes.len

  var futConns: seq[Future[Option[Connection]]]
  for node in nodes:
    let node = when node is string: parseRemotePeerInfo(node)
               else: node
    futConns.add(pm.dialPeer(RemotePeerInfo(node), proto, dialTimeout, source))

  await allFutures(futConns)
  let successfulConns = futConns.mapIt(it.read()).countIt(it.isSome)

  info "Finished dialing multiple peers", successfulConns=successfulConns, attempted=nodes.len

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(chronos.seconds(5))

# Ensures a healthy amount of connected relay peers
proc relayConnectivityLoop*(pm: PeerManager) {.async.} =
  debug "Starting relay connectivity loop"
  while pm.started:

    let maxConnections = pm.switch.connManager.inSema.size
    let numInPeers = pm.switch.connectedPeers(lpstream.Direction.In).len
    let numOutPeers = pm.switch.connectedPeers(lpstream.Direction.Out).len
    let numConPeers = numInPeers + numOutPeers

    # TODO: Enforce a given in/out peers ratio

    # Leave some room for service peers
    if numConPeers >= (maxConnections - 5):
      await sleepAsync(ConnectivityLoopInterval)
      continue

    let notConnectedPeers = pm.peerStore.getNotConnectedPeers().mapIt(RemotePeerInfo.init(it.peerId, it.addrs))
    let outsideBackoffPeers = notConnectedPeers.filterIt(pm.peerStore.canBeConnected(it.peerId,
                                                                                    pm.initialBackoffInSec,
                                                                                    pm.backoffFactor))
    let numPeersToConnect = min(min(maxConnections - numConPeers, outsideBackoffPeers.len), MaxParalelDials)

    info "Relay connectivity loop",
      connectedPeers = numConPeers,
      targetConnectedPeers = maxConnections,
      notConnectedPeers = notConnectedPeers.len,
      outsideBackoffPeers = outsideBackoffPeers.len

    await pm.connectToNodes(outsideBackoffPeers[0..<numPeersToConnect], WakuRelayCodec)

    await sleepAsync(ConnectivityLoopInterval)

proc prunePeerStore*(pm: PeerManager) =
  let numPeers = toSeq(pm.peerStore[AddressBook].book.keys).len
  let capacity = pm.peerStore.capacity
  if numPeers < capacity:
    return

  debug "Peer store capacity exceeded", numPeers = numPeers, capacity = capacity
  let peersToPrune = numPeers - capacity

  # prune peers with too many failed attempts
  var pruned = 0
  for peerId in pm.peerStore[NumberFailedConnBook].book.keys:
    if peersToPrune - pruned == 0:
      break
    if pm.peerStore[NumberFailedConnBook][peerId] >= pm.maxFailedAttempts:
      pm.peerStore.del(peerId)
      pruned += 1

  # if we still need to prune, prune peers that are not connected
  let notConnected = pm.peerStore.getNotConnectedPeers().mapIt(it.peerId)
  for peerId in notConnected:
    if peersToPrune - pruned == 0:
      break
    pm.peerStore.del(peerId)
    pruned += 1

  let afterNumPeers = toSeq(pm.peerStore[AddressBook].book.keys).len
  debug "Finished pruning peer store", beforeNumPeers = numPeers,
                                       afterNumPeers = afterNumPeers,
                                       capacity = capacity,
                                       pruned = pruned


proc prunePeerStoreLoop(pm: PeerManager) {.async.}  =
  while pm.started:
    pm.prunePeerStore()
    await sleepAsync(PrunePeerStoreInterval)


proc selectPeer*(pm: PeerManager, proto: string): Option[RemotePeerInfo] =
  debug "Selecting peer from peerstore", protocol=proto

  # Selects the best peer for a given protocol
  let peers = pm.peerStore.getPeersByProtocol(proto)

  # No criteria for selecting a peer for WakuRelay, random one
  if proto == WakuRelayCodec:
    # TODO: proper heuristic here that compares peer scores and selects "best" one. For now the first peer for the given protocol is returned
    if peers.len > 0:
      debug "Got peer from peerstore", peerId=peers[0].peerId, multi=peers[0].addrs[0], protocol=proto
      return some(peers[0].toRemotePeerInfo())
    debug "No peer found for protocol", protocol=proto
    return none(RemotePeerInfo)

  # For other protocols, we select the peer that is slotted for the given protocol
  pm.serviceSlots.withValue(proto, serviceSlot):
    debug "Got peer from service slots", peerId=serviceSlot[].peerId, multi=serviceSlot[].addrs[0], protocol=proto
    return some(serviceSlot[])

  # If not slotted, we select a random peer for the given protocol
  if peers.len > 0:
    debug "Got peer from peerstore", peerId=peers[0].peerId, multi=peers[0].addrs[0], protocol=proto
    return some(peers[0].toRemotePeerInfo())
  debug "No peer found for protocol", protocol=proto
  return none(RemotePeerInfo)

proc start*(pm: PeerManager) =
  pm.started = true
  asyncSpawn pm.relayConnectivityLoop()
  asyncSpawn pm.prunePeerStoreLoop()

proc stop*(pm: PeerManager) =
  pm.started = false
