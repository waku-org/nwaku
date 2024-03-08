when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/[options, sets, sequtils, times, strutils, math, random],
  chronos,
  chronicles,
  metrics,
  libp2p/multistream,
  libp2p/muxers/muxer,
  libp2p/nameresolving/nameresolver
import
  ../../common/nimchronos,
  ../../common/enr,
  ../../waku_core,
  ../../waku_relay,
  ../../waku_enr/sharding,
  ../../waku_enr/capabilities,
  ../../waku_metadata,
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

randomize()

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
  MaxParallelDials = 10

  # Delay between consecutive relayConnectivityLoop runs
  ConnectivityLoopInterval = chronos.minutes(1)

  # How often the peer store is pruned
  PrunePeerStoreInterval = chronos.minutes(10)

  # How often metrics and logs are shown/updated
  LogAndMetricsInterval = chronos.minutes(3)

  # Max peers that we allow from the same IP
  DefaultColocationLimit* = 5

type
  PeerManager* = ref object of RootObj
    switch*: Switch
    peerStore*: PeerStore
    wakuMetadata*: WakuMetadata
    initialBackoffInSec*: int
    backoffFactor*: int
    maxFailedAttempts*: int
    storage*: PeerStorage
    serviceSlots*: Table[string, RemotePeerInfo]
    maxRelayPeers*: int
    outRelayPeersTarget: int
    inRelayPeersTarget: int
    ipTable*: Table[string, seq[PeerId]]
    colocationLimit*: int
    started: bool
    shardedPeerManagement: bool # temp feature flag

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

proc insertOrReplace(ps: PeerStorage, remotePeerInfo: RemotePeerInfo) =
  ## Insert peer entry into persistent storage, or replace existing entry with updated info
  ps.put(remotePeerInfo).isOkOr:
    warn "failed to store peers", err = error
    waku_peers_errors.inc(labelValues = ["storage_failure"])
    return

proc addPeer*(pm: PeerManager, remotePeerInfo: RemotePeerInfo, origin = UnknownOrigin) =
  ## Adds peer to manager for the specified protocol

  if remotePeerInfo.peerId == pm.switch.peerInfo.peerId:
    # Do not attempt to manage our unmanageable self
    return

  if pm.peerStore[AddressBook][remotePeerInfo.peerId] == remotePeerInfo.addrs and
     pm.peerStore[KeyBook][remotePeerInfo.peerId] == remotePeerInfo.publicKey and
     pm.peerStore[ENRBook][remotePeerInfo.peerId].raw.len > 0:
    # Peer already managed and ENR info is already saved
    return

  trace "Adding peer to manager", peerId = remotePeerInfo.peerId, addresses = remotePeerInfo.addrs
    
  pm.peerStore[AddressBook][remotePeerInfo.peerId] = remotePeerInfo.addrs
  pm.peerStore[KeyBook][remotePeerInfo.peerId] = remotePeerInfo.publicKey
  pm.peerStore[SourceBook][remotePeerInfo.peerId] = origin
  
  if remotePeerInfo.protocols.len > 0:
    pm.peerStore[ProtoBook][remotePeerInfo.peerId] = remotePeerInfo.protocols
  
  if remotePeerInfo.enr.isSome():
    pm.peerStore[ENRBook][remotePeerInfo.peerId] = remotePeerInfo.enr.get()

  # Add peer to storage. Entry will subsequently be updated with connectedness information
  if not pm.storage.isNil:
    remotePeerInfo.connectedness = NotConnected

    pm.storage.insertOrReplace(remotePeerInfo)

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
  trace "Connecting to relay peer", wireAddr=peer.addrs, peerId=peerId, failedAttempts=failedAttempts

  var deadline = sleepAsync(dialTimeout)
  let workfut = pm.switch.connect(peerId, peer.addrs)
  
  # Can't use catch: with .withTimeout() in this case
  let res = catch: await workfut or deadline

  let reasonFailed = 
    if not workfut.finished():
      await workfut.cancelAndWait()
      "timed out"
    elif res.isErr(): res.error.msg
    else: 
      if not deadline.finished():
        await deadline.cancelAndWait()
      
      waku_peers_dials.inc(labelValues = ["successful"])
      waku_node_conns_initiated.inc(labelValues = [source])

      pm.peerStore[NumberFailedConnBook][peerId] = 0

      return true
  
  # Dial failed
  pm.peerStore[NumberFailedConnBook][peerId] = pm.peerStore[NumberFailedConnBook][peerId] + 1
  pm.peerStore[LastFailedConnBook][peerId] = Moment.init(getTime().toUnix, Second)
  pm.peerStore[ConnectionBook][peerId] = CannotConnect

  trace "Connecting relay peer failed",
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

  trace "Dialing peer", wireAddr=addrs, peerId=peerId, proto=proto

  # Dial Peer
  let dialFut = pm.switch.dial(peerId, addrs, proto)

  let res = catch:
    if await dialFut.withTimeout(dialTimeout):
      return some(dialFut.read())
    else: await cancelAndWait(dialFut)

  let reasonFailed =
    if res.isOk: "timed out"
    else: res.error.msg

  trace "Dialing peer failed", peerId=peerId, reason=reasonFailed, proto=proto

  return none(Connection)

proc loadFromStorage(pm: PeerManager) =
  ## Load peers from storage, if available
  
  trace "loading peers from storage"
  
  var amount = 0

  proc onData(remotePeerInfo: RemotePeerInfo) =
    let peerId = remotePeerInfo.peerId
    
    if pm.switch.peerInfo.peerId == peerId:
      # Do not manage self
      return

    trace "loading peer",
      peerId = peerId,
      address = remotePeerInfo.addrs,
      protocols = remotePeerInfo.protocols,
      agent = remotePeerInfo.agent,
      version = remotePeerInfo.protoVersion

    # nim-libp2p books
    pm.peerStore[AddressBook][peerId] = remotePeerInfo.addrs
    pm.peerStore[ProtoBook][peerId] = remotePeerInfo.protocols
    pm.peerStore[KeyBook][peerId] = remotePeerInfo.publicKey
    pm.peerStore[AgentBook][peerId] = remotePeerInfo.agent
    pm.peerStore[ProtoVersionBook][peerId] = remotePeerInfo.protoVersion

    # custom books
    pm.peerStore[ConnectionBook][peerId] = NotConnected  # Reset connectedness state
    pm.peerStore[DisconnectBook][peerId] = remotePeerInfo.disconnectTime
    pm.peerStore[SourceBook][peerId] = remotePeerInfo.origin
    
    if remotePeerInfo.enr.isSome():
      pm.peerStore[ENRBook][peerId] = remotePeerInfo.enr.get()

    amount.inc()

  pm.storage.getAll(onData).isOkOr:
    warn "loading peers from storage failed", err = error
    waku_peers_errors.inc(labelValues = ["storage_load_failure"])
    return

  trace "recovered peers from storage", amount = amount

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
 
  return now >= (lastFailed + backoff)

##################
# Initialisation #
##################

proc getPeerIp(pm: PeerManager, peerId: PeerId): Option[string] =
  if not pm.switch.connManager.getConnections().hasKey(peerId):
    return none(string)

  let conns = pm.switch.connManager.getConnections().getOrDefault(peerId)
  if conns.len == 0:
    return none(string)

  let obAddr = conns[0].connection.observedAddr.valueOr:
    return none(string)

  # TODO: think if circuit relay ips should be handled differently
  
  return some(obAddr.getHostname())

# called when a connection i) is created or ii) is closed
proc onConnEvent(pm: PeerManager, peerId: PeerID, event: ConnEvent) {.async.} =
  case event.kind
    of ConnEventKind.Connected:
      #let direction = if event.incoming: Inbound else: Outbound
      discard
    of ConnEventKind.Disconnected:
      discard

proc onPeerMetadata(pm: PeerManager, peerId: PeerId) {.async.} =
  # To prevent metadata protocol from breaking prev nodes, by now we only
  # disconnect if the clusterid is specified.
  if pm.wakuMetadata.clusterId == 0:
    return

  let res = catch: await pm.switch.dial(peerId, WakuMetadataCodec)

  var reason: string
  block guardClauses:
    let conn = res.valueOr:
      reason = "dial failed: " & error.msg
      break guardClauses
    
    let metadata = (await pm.wakuMetadata.request(conn)).valueOr:
      reason = "waku metatdata request failed: " & error
      break guardClauses

    let clusterId = metadata.clusterId.valueOr:
      reason = "empty cluster-id reported"
      break guardClauses

    if pm.wakuMetadata.clusterId != clusterId:
      reason = "different clusterId reported: " & $pm.wakuMetadata.clusterId & " vs " & $clusterId
      break guardClauses

    if not metadata.shards.anyIt(pm.wakuMetadata.shards.contains(it)):
      reason = "no shards in common"
      break guardClauses

    return
   
  info "disconnecting from peer", peerId=peerId, reason=reason
  asyncSpawn(pm.switch.disconnect(peerId))
  pm.peerStore.delete(peerId)

# called when a peer i) first connects to us ii) disconnects all connections from us
proc onPeerEvent(pm: PeerManager, peerId: PeerId, event: PeerEvent) {.async.} =
  if not pm.wakuMetadata.isNil() and event.kind == PeerEventKind.Joined:
    await pm.onPeerMetadata(peerId)

  var direction: PeerDirection
  var connectedness: Connectedness

  case event.kind:
    of Joined:
      direction = if event.initiator: Outbound else: Inbound
      connectedness = Connected

      if (let ip = pm.getPeerIp(peerId); ip.isSome()):
        pm.ipTable.mgetOrPut(ip.get, newSeq[PeerId]()).add(peerId)

        # in theory this should always be one, but just in case
        let peersBehindIp = pm.ipTable[ip.get]
        
        # pm.colocationLimit == 0 disables the ip colocation limit
        if pm.colocationLimit != 0 and peersBehindIp.len > pm.colocationLimit:
          for peerId in peersBehindIp[0..<(peersBehindIp.len - pm.colocationLimit)]:
            debug "Pruning connection due to ip colocation", peerId = peerId, ip = ip
            asyncSpawn(pm.switch.disconnect(peerId))
            pm.peerStore.delete(peerId)
    of Left:
      direction = UnknownDirection
      connectedness = CanConnect

      # note we cant access the peerId ip here as the connection was already closed
      for ip, peerIds in pm.ipTable.pairs:
        if peerIds.contains(peerId):
          pm.ipTable[ip] = pm.ipTable[ip].filterIt(it != peerId)
          if pm.ipTable[ip].len == 0:
            pm.ipTable.del(ip)
          break

  pm.peerStore[ConnectionBook][peerId] = connectedness
  pm.peerStore[DirectionBook][peerId] = direction

  if not pm.storage.isNil:
    var remotePeerInfo = pm.peerStore.get(peerId)
    remotePeerInfo.disconnectTime = getTime().toUnix

    pm.storage.insertOrReplace(remotePeerInfo)

proc new*(T: type PeerManager,
          switch: Switch,
          wakuMetadata: WakuMetadata = nil,
          maxRelayPeers: Option[int] = none(int),
          storage: PeerStorage = nil,
          initialBackoffInSec = InitialBackoffInSec,
          backoffFactor = BackoffFactor,
          maxFailedAttempts = MaxFailedAttempts,
          colocationLimit = DefaultColocationLimit,
          shardedPeerManagement = false): PeerManager =

  let capacity = switch.peerStore.capacity
  let maxConnections = switch.connManager.inSema.size
  if maxConnections > capacity:
    error "Max number of connections can't be greater than PeerManager capacity",
         capacity = capacity,
         maxConnections = maxConnections
    raise newException(Defect, "Max number of connections can't be greater than PeerManager capacity")

  var maxRelayPeersValue = 0
  if maxRelayPeers.isSome():
    if maxRelayPeers.get() > maxConnections:
      error "Max number of relay peers can't be greater than the max amount of connections",
           maxConnections = maxConnections,
           maxRelayPeers = maxRelayPeers.get()
      raise newException(Defect, "Max number of relay peers can't be greater than the max amount of connections")

    if maxRelayPeers.get() == maxConnections:
      warn "Max number of relay peers is equal to max amount of connections, peer won't be contributing to service peers",
           maxConnections = maxConnections,
           maxRelayPeers = maxRelayPeers.get()
    maxRelayPeersValue = maxRelayPeers.get()
  else:
    # Leave by default 20% of connections for service peers
    maxRelayPeersValue = maxConnections - (maxConnections div 5)

  # attempt to calculate max backoff to prevent potential overflows or unreasonably high values
  let backoff = calculateBackoff(initialBackoffInSec, backoffFactor, maxFailedAttempts)
  if backoff.weeks() > 1:
    error "Max backoff time can't be over 1 week",
        maxBackoff=backoff
    raise newException(Defect, "Max backoff time can't be over 1 week")

  let outRelayPeersTarget = max(maxRelayPeersValue div 3, 10)

  let pm = PeerManager(switch: switch,
                       wakuMetadata: wakuMetadata,
                       peerStore: switch.peerStore,
                       storage: storage,
                       initialBackoffInSec: initialBackoffInSec,
                       backoffFactor: backoffFactor,
                       outRelayPeersTarget: outRelayPeersTarget,
                       inRelayPeersTarget: maxRelayPeersValue - outRelayPeersTarget,
                       maxRelayPeers: maxRelayPeersValue,
                       maxFailedAttempts: maxFailedAttempts,
                       colocationLimit: colocationLimit,
                       shardedPeerManagement: shardedPeerManagement,)

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
    trace "found persistent peer storage"
    pm.loadFromStorage() # Load previously managed peers.
  else:
    trace "no peer storage found"

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

  trace "Reconnecting peers", proto=proto

  # Proto is not persisted, we need to iterate over all peers.
  for peerInfo in pm.peerStore.peers(protocolMatcher(proto)):
    # Check that the peer can be connected
    if peerInfo.connectedness == CannotConnect:
      error "Not reconnecting to unreachable or non-existing peer", peerId=peerInfo.peerId
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
      trace "Backing off before reconnect...", peerId=peerInfo.peerId, backoffTime=backoffTime
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

proc connectedPeers*(pm: PeerManager, protocol: string): (seq[PeerId], seq[PeerId]) =
  ## Returns the peerIds of physical connections (in and out)
  ## containing at least one stream with the given protocol.
  
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
  if amount <= 0:
    return
  
  let (inRelayPeers, _) = pm.connectedPeers(WakuRelayCodec)
  let connsToPrune = min(amount, inRelayPeers.len)

  for p in inRelayPeers[0..<connsToPrune]:
    trace "Pruning Peer", Peer = $p
    asyncSpawn(pm.switch.disconnect(p))

proc connectToRelayPeers*(pm: PeerManager) {.async.} =
  let (inRelayPeers, outRelayPeers) = pm.connectedPeers(WakuRelayCodec)
  let maxConnections = pm.switch.connManager.inSema.size
  let totalRelayPeers = inRelayPeers.len + outRelayPeers.len
  let inPeersTarget = maxConnections - pm.outRelayPeersTarget

  # TODO: Temporally disabled. Might be causing connection issues
  #if inRelayPeers.len > pm.inRelayPeersTarget:
  #  await pm.pruneInRelayConns(inRelayPeers.len - pm.inRelayPeersTarget)

  if outRelayPeers.len >= pm.outRelayPeersTarget:
    return

  let notConnectedPeers = pm.peerStore.getNotConnectedPeers().mapIt(RemotePeerInfo.init(it.peerId, it.addrs))
  let outsideBackoffPeers = notConnectedPeers.filterIt(pm.canBeConnected(it.peerId))
  let numPeersToConnect = min(outsideBackoffPeers.len, MaxParallelDials)

  await pm.connectToNodes(outsideBackoffPeers[0..<numPeersToConnect])

proc manageRelayPeers*(pm: PeerManager) {.async.} =
  if pm.wakuMetadata.shards.len == 0:
    return
  
  var peersToConnect: HashSet[PeerId] # Can't use RemotePeerInfo as they are ref objects
  var peersToDisconnect: int

  # Get all connected peers for Waku Relay
  var (inPeers, outPeers) = pm.connectedPeers(WakuRelayCodec)

  # Calculate in/out target number of peers for each shards
  let inTarget = pm.inRelayPeersTarget div pm.wakuMetadata.shards.len
  let outTarget = pm.outRelayPeersTarget div pm.wakuMetadata.shards.len

  for shard in pm.wakuMetadata.shards.items:
    # Filter out peer not on this shard
    let connectedInPeers = inPeers.filterIt(
      pm.peerStore.hasShard(it, uint16(pm.wakuMetadata.clusterId), uint16(shard)))

    let connectedOutPeers = outPeers.filterIt(
      pm.peerStore.hasShard(it, uint16(pm.wakuMetadata.clusterId), uint16(shard)))

    # Calculate the difference between current values and targets
    let inPeerDiff = connectedInPeers.len - inTarget
    let outPeerDiff = outTarget - connectedOutPeers.len

    if inPeerDiff > 0:
      peersToDisconnect += inPeerDiff

    if outPeerDiff <= 0:
      continue

    # Get all peers for this shard
    var connectablePeers = pm.peerStore.getPeersByShard(
      uint16(pm.wakuMetadata.clusterId), uint16(shard))
  
    let shardCount = connectablePeers.len

    connectablePeers.keepItIf(
      not pm.peerStore.isConnected(it.peerId) and
      pm.canBeConnected(it.peerId))

    let connectableCount = connectablePeers.len

    connectablePeers.keepItIf(pm.peerStore.hasCapability(it.peerId, Relay))

    let relayCount = connectablePeers.len

    debug "Sharded Peer Management",
      shard = shard,
      connectable = $connectableCount & "/" & $shardCount,
      relayConnectable = $relayCount & "/" & $shardCount,
      relayInboundTarget = $connectedInPeers.len & "/" & $inTarget,
      relayOutboundTarget = $connectedOutPeers.len & "/" & $outTarget
      
    # Always pick random connectable relay peers
    shuffle(connectablePeers)

    let length = min(outPeerDiff, connectablePeers.len)
    for peer in connectablePeers[0..<length]:
      trace "Peer To Connect To", peerId = $peer.peerId
      peersToConnect.incl(peer.peerId)

  await pm.pruneInRelayConns(peersToDisconnect)
  
  if peersToConnect.len == 0:
    return

  let uniquePeers = toSeq(peersToConnect).mapIt(pm.peerStore.get(it))

  # Connect to all nodes
  for i in countup(0, uniquePeers.len, MaxParallelDials):
    let stop = min(i + MaxParallelDials, uniquePeers.len)
    trace "Connecting to Peers", peerIds = $uniquePeers[i..<stop]
    await pm.connectToNodes(uniquePeers[i..<stop])

proc prunePeerStore*(pm: PeerManager) =
  let numPeers = pm.peerStore[AddressBook].book.len
  let capacity = pm.peerStore.capacity
  if numPeers <= capacity:
    return

  trace "Peer store capacity exceeded", numPeers = numPeers, capacity = capacity
  let pruningCount = numPeers - capacity
  var peersToPrune: HashSet[PeerId]

  # prune failed connections
  for peerId, count in pm.peerStore[NumberFailedConnBook].book.pairs:
    if count < pm.maxFailedAttempts:
      continue

    if peersToPrune.len >= pruningCount:
      break

    peersToPrune.incl(peerId)
  
  var notConnected = pm.peerStore.getNotConnectedPeers().mapIt(it.peerId)

  # Always pick random non-connected peers
  shuffle(notConnected)

  var shardlessPeers: seq[PeerId]
  var peersByShard = initTable[uint16, seq[PeerId]]()

  for peer in notConnected:
    if not pm.peerStore[ENRBook].contains(peer):
      shardlessPeers.add(peer)
      continue

    let record = pm.peerStore[ENRBook][peer]

    let rec = record.toTyped().valueOr:
      shardlessPeers.add(peer)
      continue

    let rs = rec.relaySharding().valueOr:
      shardlessPeers.add(peer)
      continue

    for shard in rs.shardIds:
      peersByShard.mgetOrPut(shard, @[peer]).add(peer)

  # prune not connected peers without shard
  for peer in shardlessPeers:
    if peersToPrune.len >= pruningCount:
      break

    peersToPrune.incl(peer)

  # calculate the avg peers per shard
  let total = sum(toSeq(peersByShard.values).mapIt(it.len))
  let avg = min(1, total div max(1, peersByShard.len))

  # prune peers from shard with higher than avg count
  for shard, peers in peersByShard.pairs:
    let count = max(peers.len - avg, 0)
    for peer in peers[0..count]:
      if peersToPrune.len >= pruningCount:
        break

      peersToPrune.incl(peer)

  for peer in peersToPrune:
    pm.peerStore.delete(peer)

  let afterNumPeers = pm.peerStore[AddressBook].book.len

  trace "Finished pruning peer store", beforeNumPeers = numPeers,
                                       afterNumPeers = afterNumPeers,
                                       capacity = capacity,
                                       pruned = peersToPrune.len

proc selectPeer*(pm: PeerManager, proto: string, shard: Option[PubsubTopic] = none(PubsubTopic)): Option[RemotePeerInfo] =
  trace "Selecting peer from peerstore", protocol=proto

  # Selects the best peer for a given protocol
  var peers = pm.peerStore.getPeersByProtocol(proto)

  if shard.isSome():
    peers.keepItIf((it.enr.isSome() and it.enr.get().containsShard(shard.get())))

  # No criteria for selecting a peer for WakuRelay, random one
  if proto == WakuRelayCodec:
    # TODO: proper heuristic here that compares peer scores and selects "best" one. For now the first peer for the given protocol is returned
    if peers.len > 0:
      trace "Got peer from peerstore", peerId=peers[0].peerId, multi=peers[0].addrs[0], protocol=proto
      return some(peers[0])
    trace "No peer found for protocol", protocol=proto
    return none(RemotePeerInfo)

  # For other protocols, we select the peer that is slotted for the given protocol
  pm.serviceSlots.withValue(proto, serviceSlot):
    trace "Got peer from service slots", peerId=serviceSlot[].peerId, multi=serviceSlot[].addrs[0], protocol=proto
    return some(serviceSlot[])

  # If not slotted, we select a random peer for the given protocol
  if peers.len > 0:
    trace "Got peer from peerstore", peerId=peers[0].peerId, multi=peers[0].addrs[0], protocol=proto
    return some(peers[0])
  trace "No peer found for protocol", protocol=proto
  return none(RemotePeerInfo)

# Prunes peers from peerstore to remove old/stale ones
proc prunePeerStoreLoop(pm: PeerManager) {.async.}  =
  trace "Starting prune peerstore loop"
  while pm.started:
    pm.prunePeerStore()
    await sleepAsync(PrunePeerStoreInterval)

# Ensures a healthy amount of connected relay peers
proc relayConnectivityLoop*(pm: PeerManager) {.async.} =
  trace "Starting relay connectivity loop"
  while pm.started:
    if pm.shardedPeerManagement:
      await pm.manageRelayPeers()
    else: await pm.connectToRelayPeers()
    await sleepAsync(ConnectivityLoopInterval)

proc logAndMetrics(pm: PeerManager) {.async.} =
  heartbeat "Scheduling log and metrics run", LogAndMetricsInterval:
    # log metrics
    let (inRelayPeers, outRelayPeers) = pm.connectedPeers(WakuRelayCodec)
    let maxConnections = pm.switch.connManager.inSema.size
    let notConnectedPeers = pm.peerStore.getNotConnectedPeers().mapIt(RemotePeerInfo.init(it.peerId, it.addrs))
    let outsideBackoffPeers = notConnectedPeers.filterIt(pm.canBeConnected(it.peerId))
    let totalConnections = pm.switch.connManager.getConnections().len

    info "Relay peer connections",
      inRelayConns = $inRelayPeers.len & "/" & $pm.inRelayPeersTarget,
      outRelayConns = $outRelayPeers.len & "/" & $pm.outRelayPeersTarget,
      totalConnections = $totalConnections & "/" & $maxConnections,
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
  asyncSpawn pm.logAndMetrics()

proc stop*(pm: PeerManager) =
  pm.started = false