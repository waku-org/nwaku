when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/[options, sets, sequtils, times, strutils, math],
  chronos,
  chronicles,
  metrics,
  libp2p/multistream,
  libp2p/muxers/muxer,
  libp2p/nameresolving/nameresolver
import
  ../../../common/nimchronos,
  ../../waku_core,
  ../../waku_relay,
  ./peer_store/peer_storage,
  ./waku_peer_store

export waku_peer_store, peer_storage, peers

declareCounter waku_peers_dials, "Number of peer dials", ["outcome"]
# TODO: Populate from PeerStore.Source when ready
declarePublicCounter waku_node_conns_initiated, "Number of connections initiated", ["source"]
declarePublicGauge waku_peers_errors, "Number of peer manager errors", ["type"]
declarePublicGauge waku_connected_peers, "Number of physical connections per direction and protocol", labels = ["direction", "protocol"]
declarePublicGauge waku_streams_peers, "Number of streams per direction and protocol", labels = ["direction", "protocol"]
declarePublicGauge waku_peer_store_size, "Number of peers managed by the peer store"
declarePublicGauge waku_service_peers, "Service peer protocol and multiaddress ", labels = ["protocol", "peerId"]

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
  ConnectivityLoopInterval = chronos.seconds(15)

  # How often the peer store is pruned
  PrunePeerStoreInterval = chronos.minutes(5)

  # How often metrics and logs are shown/updated
  LogAndMetricsInterval = chronos.seconds(60)

  # Prune by ip interval
  PruneByIpInterval = chronos.seconds(30)

  # Max peers that we allow from the same IP
  ColocationLimit = 5

type
  PeerManager* = ref object of RootObj
    switch*: Switch
    peerStore*: PeerStore
    initialBackoffInSec*: int
    backoffFactor*: int
    maxFailedAttempts*: int
    storage: PeerStorage
    serviceSlots*: Table[string, RemotePeerInfo]
    outPeersTarget*: int
    ipTable*: Table[string, seq[PeerId]]
    colocationLimit*: int
    started: bool

proc protocolMatcher*(codec: string): Matcher =
  ## Returns a protocol matcher function for the provided codec
  proc match(proto: string): bool {.gcsafe.} =
    ## Matches a proto with any postfix to the provided codec.
    ## E.g. if the codec is `/vac/waku/filter/2.0.0` it matches the protos:
    ## `/vac/waku/filter/2.0.0`, `/vac/waku/filter/2.0.0-beta3`, `/vac/waku/filter/2.0.0-actualnonsense`
    return proto.startsWith(codec)

  return match

proc calculateBackoff(initialBackoffInSec: int,
                      backoffFactor: int,
                      failedAttempts: int): timer.Duration =
  if failedAttempts == 0:
    return chronos.seconds(0)
  return chronos.seconds(initialBackoffInSec*(backoffFactor^(failedAttempts-1)))

####################
# Helper functions #
####################

proc insertOrReplace(ps: PeerStorage,
                     peerId: PeerID,
                     remotePeerInfo: RemotePeerInfo,
                     connectedness: Connectedness,
                     disconnectTime: int64 = 0) =
  # Insert peer entry into persistent storage, or replace existing entry with updated info
  let res = ps.put(peerId, remotePeerInfo, connectedness, disconnectTime)
  if res.isErr:
    warn "failed to store peers", err = res.error
    waku_peers_errors.inc(labelValues = ["storage_failure"])

proc addPeer*(pm: PeerManager, remotePeerInfo: RemotePeerInfo, origin = UnknownOrigin) =
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

  trace "Adding peer to manager", peerId = remotePeerInfo.peerId, addresses = remotePeerInfo.addrs

  pm.peerStore[AddressBook][remotePeerInfo.peerId] = remotePeerInfo.addrs
  pm.peerStore[KeyBook][remotePeerInfo.peerId] = publicKey
  pm.peerStore[SourceBook][remotePeerInfo.peerId] = origin

  if remotePeerInfo.enr.isSome():
    pm.peerStore[ENRBook][remotePeerInfo.peerId] = remotePeerInfo.enr.get()

  # Add peer to storage. Entry will subsequently be updated with connectedness information
  if not pm.storage.isNil:
    pm.storage.insertOrReplace(remotePeerInfo.peerId, pm.peerStore.get(remotePeerInfo.peerId), NotConnected)

# Connects to a given node. Note that this function uses `connect` and
# does not provide a protocol. Streams for relay (gossipsub) are created
# automatically without the needing to dial.
proc connectRelay*(pm: PeerManager,
                   peer: RemotePeerInfo,
                   dialTimeout = DefaultDialTimeout,
                   source = "api"): Future[bool] {.async.} =

  let peerId = peer.peerId

  # Do not attempt to dial self
  if peerId == pm.switch.peerInfo.peerId:
    return false

  if not pm.peerStore.hasPeer(peerId, WakuRelayCodec):
    pm.addPeer(peer)

  let failedAttempts = pm.peerStore[NumberFailedConnBook][peerId]
  debug "Connecting to relay peer", wireAddr=peer.addrs, peerId=peerId, failedAttempts=failedAttempts

  var deadline = sleepAsync(dialTimeout)
  var workfut = pm.switch.connect(peerId, peer.addrs)
  var reasonFailed = ""

  try:
    await workfut or deadline
    if workfut.finished():
      if not deadline.finished():
        deadline.cancel()
      waku_peers_dials.inc(labelValues = ["successful"])
      waku_node_conns_initiated.inc(labelValues = [source])
      pm.peerStore[NumberFailedConnBook][peerId] = 0
      return true
    else:
      reasonFailed = "timed out"
      await cancelAndWait(workfut)
  except CatchableError as exc:
    reasonFailed = "remote peer failed"

  # Dial failed
  pm.peerStore[NumberFailedConnBook][peerId] = pm.peerStore[NumberFailedConnBook][peerId] + 1
  pm.peerStore[LastFailedConnBook][peerId] = Moment.init(getTime().toUnix, Second)
  pm.peerStore[ConnectionBook][peerId] = CannotConnect

  debug "Connecting relay peer failed",
          peerId = peerId,
          reason = reasonFailed,
          failedAttempts = pm.peerStore[NumberFailedConnBook][peerId]
  waku_peers_dials.inc(labelValues = [reasonFailed])

  return false

# Dialing should be used for just protocols that require a stream to write and read
# This shall not be used to dial Relay protocols, since that would create
# unneccesary unused streams.
proc dialPeer(pm: PeerManager,
              peerId: PeerID,
              addrs: seq[MultiAddress],
              proto: string,
              dialTimeout = DefaultDialTimeout,
              source = "api"): Future[Option[Connection]] {.async.} =

  if peerId == pm.switch.peerInfo.peerId:
    error "could not dial self"
    return none(Connection)

  if proto == WakuRelayCodec:
    error "dial shall not be used to connect to relays"
    return none(Connection)

  debug "Dialing peer", wireAddr=addrs, peerId=peerId, proto=proto

  # Dial Peer
  let dialFut = pm.switch.dial(peerId, addrs, proto)
  var reasonFailed = ""
  try:
    if (await dialFut.withTimeout(dialTimeout)):
      return some(dialFut.read())
    else:
      reasonFailed = "timeout"
      await cancelAndWait(dialFut)
  except CatchableError as exc:
    reasonFailed = "failed"

  debug "Dialing peer failed", peerId=peerId, reason=reasonFailed, proto=proto

  return none(Connection)

proc loadFromStorage(pm: PeerManager) =
  debug "loading peers from storage"
  # Load peers from storage, if available
  proc onData(peerId: PeerID, remotePeerInfo: RemotePeerInfo, connectedness: Connectedness, disconnectTime: int64) =
    trace "loading peer", peerId=peerId, connectedness=connectedness

    if peerId == pm.switch.peerInfo.peerId:
      # Do not manage self
      return

    # nim-libp2p books
    pm.peerStore[AddressBook][peerId] = remotePeerInfo.addrs
    pm.peerStore[ProtoBook][peerId] = remotePeerInfo.protocols
    pm.peerStore[KeyBook][peerId] = remotePeerInfo.publicKey
    pm.peerStore[AgentBook][peerId] = remotePeerInfo.agent
    pm.peerStore[ProtoVersionBook][peerId] = remotePeerInfo.protoVersion

    # custom books
    pm.peerStore[ConnectionBook][peerId] = NotConnected  # Reset connectedness state
    pm.peerStore[DisconnectBook][peerId] = disconnectTime
    pm.peerStore[SourceBook][peerId] = remotePeerInfo.origin

  let res = pm.storage.getAll(onData)
  if res.isErr:
    warn "failed to load peers from storage", err = res.error
    waku_peers_errors.inc(labelValues = ["storage_load_failure"])
  else:
    debug "successfully queried peer storage"

proc canBeConnected*(pm: PeerManager,
                     peerId: PeerId): bool =
  # Returns if we can try to connect to this peer, based on past failed attempts
  # It uses an exponential backoff. Each connection attempt makes us
  # wait more before trying again.
  let failedAttempts = pm.peerStore[NumberFailedConnBook][peerId]

  # if it never errored, we can try to connect
  if failedAttempts == 0:
    return true

  # if there are too many failed attempts, do not reconnect
  if failedAttempts >= pm.maxFailedAttempts:
    return false

  # If it errored we wait an exponential backoff from last connection
  # the more failed attempts, the greater the backoff since last attempt
  let now = Moment.init(getTime().toUnix, Second)
  let lastFailed = pm.peerStore[LastFailedConnBook][peerId]
  let backoff = calculateBackoff(pm.initialBackoffInSec, pm.backoffFactor, failedAttempts)
  if now >= (lastFailed + backoff):
    return true
  return false

##################
# Initialisation #
##################

# called when a connection i) is created or ii) is closed
proc onConnEvent(pm: PeerManager, peerId: PeerID, event: ConnEvent) {.async.} =
  case event.kind
  of ConnEventKind.Connected:
    let direction = if event.incoming: Inbound else: Outbound
    discard
  of ConnEventKind.Disconnected:
    discard

# called when a peer i) first connects to us ii) disconnects all connections from us
proc onPeerEvent(pm: PeerManager, peerId: PeerId, event: PeerEvent) {.async.} =
  var direction: PeerDirection
  var connectedness: Connectedness

  if event.kind == PeerEventKind.Joined:
    direction = if event.initiator: Outbound else: Inbound
    connectedness = Connected
  elif event.kind == PeerEventKind.Left:
    direction = UnknownDirection
    connectedness = CanConnect

  pm.peerStore[ConnectionBook][peerId] = connectedness
  pm.peerStore[DirectionBook][peerId] = direction
  if not pm.storage.isNil:
    pm.storage.insertOrReplace(peerId, pm.peerStore.get(peerId), connectedness, getTime().toUnix)

proc updateIpTable*(pm: PeerManager) =
  # clean table
  pm.ipTable = initTable[string, seq[PeerId]]()

  # populate ip->peerIds from existing out/in connections
  for peerId, conn in pm.switch.connManager.getConnections():
    if conn.len == 0:
      continue

    # we may want to enable it only in inbound peers
    #if conn[0].connection.transportDir != In:
    #  continue

    # assumes just one physical connection per peer
    let observedAddr = conn[0].connection.observedAddr
    if observedAddr.isSome:
      # TODO: think if circuit relay ips should be handled differently
      let ip = observedAddr.get.getHostname()
      pm.ipTable.mgetOrPut(ip, newSeq[PeerId]()).add(peerId)


proc new*(T: type PeerManager,
          switch: Switch,
          storage: PeerStorage = nil,
          initialBackoffInSec = InitialBackoffInSec,
          backoffFactor = BackoffFactor,
          maxFailedAttempts = MaxFailedAttempts,
          colocationLimit = ColocationLimit,): PeerManager =

  let capacity = switch.peerStore.capacity
  let maxConnections = switch.connManager.inSema.size
  if maxConnections > capacity:
    error "Max number of connections can't be greater than PeerManager capacity",
         capacity = capacity,
         maxConnections = maxConnections
    raise newException(Defect, "Max number of connections can't be greater than PeerManager capacity")

  # attempt to calculate max backoff to prevent potential overflows or unreasonably high values
  let backoff = calculateBackoff(initialBackoffInSec, backoffFactor, maxFailedAttempts)
  if backoff.weeks() > 1:
    error "Max backoff time can't be over 1 week",
        maxBackoff=backoff
    raise newException(Defect, "Max backoff time can't be over 1 week")

  let pm = PeerManager(switch: switch,
                       peerStore: switch.peerStore,
                       storage: storage,
                       initialBackoffInSec: initialBackoffInSec,
                       backoffFactor: backoffFactor,
                       outPeersTarget: max(maxConnections div 10, 10),
                       maxFailedAttempts: maxFailedAttempts,
                       colocationLimit: colocationLimit)

  proc connHook(peerId: PeerID, event: ConnEvent): Future[void] {.gcsafe.} =
    onConnEvent(pm, peerId, event)

  proc peerHook(peerId: PeerId, event: PeerEvent): Future[void] {.gcsafe.} =
    onPeerEvent(pm, peerId, event)

  proc peerStoreChanged(peerId: PeerId) {.gcsafe.} =
    waku_peer_store_size.set(toSeq(pm.peerStore[AddressBook].book.keys).len.int64)

  # currently disabled
  #pm.switch.addConnEventHandler(connHook, ConnEventKind.Connected)
  #pm.switch.addConnEventHandler(connHook, ConnEventKind.Disconnected)

  pm.switch.addPeerEventHandler(peerHook, PeerEventKind.Joined)
  pm.switch.addPeerEventHandler(peerHook, PeerEventKind.Left)

  # called every time the peerstore is updated
  pm.peerStore[AddressBook].addHandler(peerStoreChanged)

  pm.serviceSlots = initTable[string, RemotePeerInfo]()
  pm.ipTable = initTable[string, seq[PeerId]]()

  if not storage.isNil():
    debug "found persistent peer storage"
    pm.loadFromStorage() # Load previously managed peers.
  else:
    debug "no peer storage found"

  return pm

#####################
# Manager interface #
#####################

proc addServicePeer*(pm: PeerManager, remotePeerInfo: RemotePeerInfo, proto: string) =
  # Do not add relay peers
  if proto == WakuRelayCodec:
    warn "Can't add relay peer to service peers slots"
    return

  info "Adding peer to service slots", peerId = remotePeerInfo.peerId, addr = remotePeerInfo.addrs[0], service = proto
  waku_service_peers.set(1, labelValues = [$proto, $remotePeerInfo.addrs[0]])

   # Set peer for service slot
  pm.serviceSlots[proto] = remotePeerInfo

  pm.addPeer(remotePeerInfo)

proc reconnectPeers*(pm: PeerManager,
                     proto: string,
                     backoff: chronos.Duration = chronos.seconds(0)) {.async.} =
  ## Reconnect to peers registered for this protocol. This will update connectedness.
  ## Especially useful to resume connections from persistent storage after a restart.

  debug "Reconnecting peers", proto=proto

  # Proto is not persisted, we need to iterate over all peers.
  for peerInfo in pm.peerStore.peers(protocolMatcher(proto)):
    # Check that the peer can be connected
    if peerInfo.connectedness == CannotConnect:
      debug "Not reconnecting to unreachable or non-existing peer", peerId=peerInfo.peerId
      continue

    # Respect optional backoff period where applicable.
    let
      # TODO: Add method to peerStore (eg isBackoffExpired())
      disconnectTime = Moment.init(peerInfo.disconnectTime, Second)  # Convert
      currentTime = Moment.init(getTime().toUnix, Second) # Current time comparable to persisted value
      backoffTime = disconnectTime + backoff - currentTime # Consider time elapsed since last disconnect

    trace "Respecting backoff", backoff=backoff, disconnectTime=disconnectTime, currentTime=currentTime, backoffTime=backoffTime

    # TODO: This blocks the whole function. Try to connect to another peer in the meantime.
    if backoffTime > ZeroDuration:
      debug "Backing off before reconnect...", peerId=peerInfo.peerId, backoffTime=backoffTime
      # We disconnected recently and still need to wait for a backoff period before connecting
      await sleepAsync(backoffTime)

    discard await pm.connectRelay(peerInfo)

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

  # First add dialed peer info to peer store, if it does not exist yet..
  # TODO: nim libp2p peerstore already adds them
  if not pm.peerStore.hasPeer(remotePeerInfo.peerId, proto):
    trace "Adding newly dialed peer to manager", peerId= $remotePeerInfo.peerId, address= $remotePeerInfo.addrs[0], proto= proto
    pm.addPeer(remotePeerInfo)

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
                     dialTimeout = DefaultDialTimeout,
                     source = "api") {.async.} =
  if nodes.len == 0:
    return

  info "Dialing multiple peers", numOfPeers = nodes.len

  var futConns: seq[Future[bool]]
  for node in nodes:
    let node = parsePeerInfo(node)
    if node.isOk():
      futConns.add(pm.connectRelay(node.value))
    else:
      error "Couldn't parse node info", error = node.error

  await allFutures(futConns)
  let successfulConns = futConns.mapIt(it.read()).countIt(it == true)

  info "Finished dialing multiple peers", successfulConns=successfulConns, attempted=nodes.len

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(chronos.seconds(5))

# Returns the peerIds of physical connections (in and out)
# containing at least one stream with the given protocol.
proc connectedPeers*(pm: PeerManager, protocol: string): (seq[PeerId], seq[PeerId]) =
  var inPeers: seq[PeerId]
  var outPeers: seq[PeerId]

  for peerId, muxers in pm.switch.connManager.getConnections():
    for peerConn in muxers:
      let streams = peerConn.getStreams()
      if streams.anyIt(it.protocol == protocol):
        if peerConn.connection.transportDir == Direction.In:
          inPeers.add(peerId)
        elif peerConn.connection.transportDir == Direction.Out:
          outPeers.add(peerId)

  return (inPeers, outPeers)

proc getNumStreams*(pm: PeerManager, protocol: string): (int, int) =
  var
    numStreamsIn = 0
    numStreamsOut = 0
  for peerId, muxers in pm.switch.connManager.getConnections():
    for peerConn in muxers:
        for stream in peerConn.getStreams():
          if stream.protocol == protocol:
            if stream.dir == Direction.In:
              numStreamsIn += 1
            elif stream.dir == Direction.Out:
              numStreamsOut += 1
  return (numStreamsIn, numStreamsOut)

proc pruneInRelayConns(pm: PeerManager, amount: int) {.async.} =
  let (inRelayPeers, outRelayPeers) = pm.connectedPeers(WakuRelayCodec)
  let connsToPrune = min(amount, inRelayPeers.len)

  for p in inRelayPeers[0..<connsToPrune]:
    await pm.switch.disconnect(p)

proc pruneConnsByIp*(pm: PeerManager) {.async.} =
  ## prunes connections based on ip colocation, allowing no more
  ## than ColocationLimit inbound connections from same ip
  ##

  # update the table tracking ip and the connected peers
  pm.updateIpTable()

  # trigger disconnections based on colocationLimit
  for ip, peersInIp in pm.ipTable.pairs:
    if peersInIp.len > pm.colocationLimit:
      let connsToPrune = peersInIp.len - pm.colocationLimit
      for peerId in peersInIp[0..<connsToPrune]:
        debug "Pruning connection due to ip colocation", peerId = peerId, ip = ip
        await pm.switch.disconnect(peerId)
        pm.peerStore.delete(peerId)

proc connectToRelayPeers*(pm: PeerManager) {.async.} =
  let (inRelayPeers, outRelayPeers) = pm.connectedPeers(WakuRelayCodec)
  let maxConnections = pm.switch.connManager.inSema.size
  let totalRelayPeers = inRelayPeers.len + outRelayPeers.len
  let inPeersTarget = maxConnections - pm.outPeersTarget

  if inRelayPeers.len > inPeersTarget:
    await pm.pruneInRelayConns(inRelayPeers.len-inPeersTarget)

  if outRelayPeers.len >= pm.outPeersTarget:
    return

  # Leave some room for service peers
  if totalRelayPeers >= (maxConnections - 5):
    return

  let notConnectedPeers = pm.peerStore.getNotConnectedPeers().mapIt(RemotePeerInfo.init(it.peerId, it.addrs))
  let outsideBackoffPeers = notConnectedPeers.filterIt(pm.canBeConnected(it.peerId))
  let numPeersToConnect = min(min(maxConnections - totalRelayPeers, outsideBackoffPeers.len), MaxParalelDials)

  await pm.connectToNodes(outsideBackoffPeers[0..<numPeersToConnect])

proc prunePeerStore*(pm: PeerManager) =
  let numPeers = toSeq(pm.peerStore[AddressBook].book.keys).len
  let capacity = pm.peerStore.capacity
  if numPeers < capacity:
    return

  debug "Peer store capacity exceeded", numPeers = numPeers, capacity = capacity
  let peersToPrune = numPeers - capacity

  # prune peers with too many failed attempts
  var pruned = 0
  # copy to avoid modifying the book while iterating
  let peerKeys = toSeq(pm.peerStore[NumberFailedConnBook].book.keys)
  for peerId in peerKeys:
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

proc selectPeer*(pm: PeerManager, proto: string): Option[RemotePeerInfo] =
  debug "Selecting peer from peerstore", protocol=proto

  # Selects the best peer for a given protocol
  let peers = pm.peerStore.getPeersByProtocol(proto)

  # No criteria for selecting a peer for WakuRelay, random one
  if proto == WakuRelayCodec:
    # TODO: proper heuristic here that compares peer scores and selects "best" one. For now the first peer for the given protocol is returned
    if peers.len > 0:
      debug "Got peer from peerstore", peerId=peers[0].peerId, multi=peers[0].addrs[0], protocol=proto
      return some(peers[0])
    debug "No peer found for protocol", protocol=proto
    return none(RemotePeerInfo)

  # For other protocols, we select the peer that is slotted for the given protocol
  pm.serviceSlots.withValue(proto, serviceSlot):
    debug "Got peer from service slots", peerId=serviceSlot[].peerId, multi=serviceSlot[].addrs[0], protocol=proto
    return some(serviceSlot[])

  # If not slotted, we select a random peer for the given protocol
  if peers.len > 0:
    debug "Got peer from peerstore", peerId=peers[0].peerId, multi=peers[0].addrs[0], protocol=proto
    return some(peers[0])
  debug "No peer found for protocol", protocol=proto
  return none(RemotePeerInfo)

proc pruneConnsByIpLoop(pm: PeerManager) {.async.}  =
  debug "Starting prune peer by ip loop"
  while pm.started:
    await pm.pruneConnsByIp()
    await sleepAsync(PruneByIpInterval)

# Prunes peers from peerstore to remove old/stale ones
proc prunePeerStoreLoop(pm: PeerManager) {.async.}  =
  debug "Starting prune peerstore loop"
  while pm.started:
    pm.prunePeerStore()
    await sleepAsync(PrunePeerStoreInterval)

# Ensures a healthy amount of connected relay peers
proc relayConnectivityLoop*(pm: PeerManager) {.async.} =
  debug "Starting relay connectivity loop"
  while pm.started:
    await pm.connectToRelayPeers()
    await sleepAsync(ConnectivityLoopInterval)

proc logAndMetrics(pm: PeerManager) {.async.} =
  heartbeat "Scheduling log and metrics run", LogAndMetricsInterval:
    # log metrics
    let (inRelayPeers, outRelayPeers) = pm.connectedPeers(WakuRelayCodec)
    let maxConnections = pm.switch.connManager.inSema.size
    let totalRelayPeers = inRelayPeers.len + outRelayPeers.len
    let inPeersTarget = maxConnections - pm.outPeersTarget
    let notConnectedPeers = pm.peerStore.getNotConnectedPeers().mapIt(RemotePeerInfo.init(it.peerId, it.addrs))
    let outsideBackoffPeers = notConnectedPeers.filterIt(pm.canBeConnected(it.peerId))

    info "Relay peer connections",
      inRelayConns = $inRelayPeers.len & "/" & $inPeersTarget,
      outRelayConns = $outRelayPeers.len & "/" & $pm.outPeersTarget,
      totalRelayConns = totalRelayPeers,
      maxConnections = maxConnections,
      notConnectedPeers = notConnectedPeers.len,
      outsideBackoffPeers = outsideBackoffPeers.len

    # update prometheus metrics
    for proto in pm.peerStore.getWakuProtos():
      let (protoConnsIn, protoConnsOut) = pm.connectedPeers(proto)
      let (protoStreamsIn, protoStreamsOut) = pm.getNumStreams(proto)
      waku_connected_peers.set(protoConnsIn.len.float64, labelValues = [$Direction.In, proto])
      waku_connected_peers.set(protoConnsOut.len.float64, labelValues = [$Direction.Out, proto])
      waku_streams_peers.set(protoStreamsIn.float64, labelValues = [$Direction.In, proto])
      waku_streams_peers.set(protoStreamsOut.float64, labelValues = [$Direction.Out, proto])

proc start*(pm: PeerManager) =
  pm.started = true
  asyncSpawn pm.relayConnectivityLoop()
  asyncSpawn pm.prunePeerStoreLoop()
  asyncSpawn pm.pruneConnsByIpLoop()
  asyncSpawn pm.logAndMetrics()

proc stop*(pm: PeerManager) =
  pm.started = false
