{.push raises: [].}

import
  results,
  std/[sets, random, sequtils, json, strutils, tables],
  chronos,
  chronicles,
  libp2p/protocols/rendezvous,
  libp2p/protocols/pubsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p_mix/pool,
  logos_delivery/kernel/common/health/connection_status,
  logos_delivery/kernel/events/kernel_events,
  # EventConnectionStatusChange
  logos_delivery/kernel/[
    protocols/relay/protocol,
    protocols/mix/protocol,
    events/health_events,
    events/peer_events,
    rln/rln_evm/group_manager,
    rln/rln_evm/conversion_utils,
    rln/rln_plugin,
    protocols/protocols,
    discovery/discovery,
    metrics_server,
    peer_manager/peer_manager,
    health_monitor/peer_ping,
    health_monitor/event_loop_monitor,
  ],
  logos_delivery/kernel/peer_manager/online_monitor,
  logos_delivery/kernel/common/health/health_status,
  logos_delivery/kernel/common/health/health_report,
  logos_delivery/kernel/common/health/connection_status,
  logos_delivery/kernel/common/health/protocol_health,
  logos_delivery/kernel/common/health/health_requests

## This module is aimed to check the state of the "self" Waku Node

# randomize initializes sdt/random's random number generator
# if not called, the outcome of randomization procedures will be the same in every run
random.randomize()

type ConnectionStatusAdjuster* = proc(
  status: ConnectionStatus, protocols: seq[ProtocolHealth]
): ConnectionStatus {.gcsafe, raises: [].}
  # Allows an upper layer to adjust the computed connection status based on additional criteria.

type NodeHealthMonitor* = ref object of RootObj
  nodeHealth: HealthStatus
  protocols: Protocols
  discovery: Discovery
  peerManager: PeerManager
  switch: Switch
  brokerCtx: BrokerContext
  isStarted: proc(): bool {.gcsafe, raises: [].}
  onlineMonitor*: OnlineMonitor
  keepAliveFut: Future[void]
  healthLoopFut: Future[void]
  eventLoopMonitorFut: Future[void]
  healthUpdateEvent: AsyncEvent
  connectionStatus: ConnectionStatus
  onConnectionStatusChange*: ConnectionStatusChangeHandler
  cachedProtocols: seq[ProtocolHealth]
    ## state of each protocol to report.
    ## calculated on last event that can change any protocol's state so fetching a report is fast.
  strength: Table[ProtocolName, int]
    ## latest known connectivity strength (e.g. connected peer count) metric for each protocol.
    ## if it doesn't make sense for the protocol in question, this is set to zero.
  relayObserver: PubSubObserver
  peerEventListener: WakuPeerEventListener
  shardHealthListener: EventShardTopicHealthChangeListener
  eventLoopLagExceeded: bool
    ## set to true when the chronos event loop lag exceeds the severe threshold,
    ## causing the node health to be reported as EVENT_LOOP_LAGGING until lag recovers.
  adjustConnectionStatus*: ConnectionStatusAdjuster
    ## lets an upper layer tighten the computed status; set before start

proc publishProtocolHealth(hm: NodeHealthMonitor, protocols: seq[ProtocolHealth]) =
  ## Stores the records of one pass. Emits `EventProtocolHealthChange` for
  ## each protocol whose status changed. A change of the description alone
  ## emits no event.
  let previous = hm.cachedProtocols
  hm.cachedProtocols = protocols
  for current in protocols:
    if previous.anyIt(it.protocol == current.protocol and it.health == current.health):
      continue
    EventProtocolHealthChange.emit(hm.brokerCtx, current)

func reportedProtocolHealth*(
    hm: NodeHealthMonitor, protocol: ProtocolName
): ProtocolHealth =
  ## The record the last pass stored for `protocol`. Before the first pass
  ## the status is `NOT_MOUNTED`.
  for p in hm.cachedProtocols:
    if p.protocol == $protocol:
      return p
  return ProtocolHealth.init(protocol)

func getHealth*(report: HealthReport, kind: ProtocolName): ProtocolHealth =
  for h in report.protocolsHealth:
    if h.protocol == $kind:
      return h
  # Shouldn't happen, but if it does, then assume protocol is not mounted
  return ProtocolHealth.init(kind)

proc countCapablePeers(hm: NodeHealthMonitor, codec: string): int =
  if isNil(hm.peerManager):
    return 0

  return hm.peerManager.getCapablePeersCount(codec)

proc getRelayHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.RelayProtocol)

  if isNil(hm.protocols.relay):
    hm.strength[ProtocolName.RelayProtocol] = 0
    return p.notMounted()

  let relayPeers = hm.protocols.relay.getConnectedPubSubPeers(pubsubTopic = "").valueOr:
    hm.strength[ProtocolName.RelayProtocol] = 0
    return p.notMounted()

  let count = relayPeers.len
  hm.strength[ProtocolName.RelayProtocol] = count
  if count == 0:
    return p.notReady("No connected peers")

  return p.ready()

proc getRlnRelayHealth(hm: NodeHealthMonitor): Future[ProtocolHealth] {.async.} =
  var p = ProtocolHealth.init(ProtocolName.RlnRelayProtocol)
  let plugin = hm.protocols.rlnPlugin.valueOr:
    return p.notMounted()
  if plugin.isReady.isNil():
    return p.notReady("The mounted RLN backend does not report its readiness")

  const FutIsReadyTimout = 5.seconds

  let isReadyStateFut = plugin.isReady()
  if not await isReadyStateFut.withTimeout(FutIsReadyTimout):
    return p.notReady("Ready state check timed out")

  try:
    if not isReadyStateFut.completed():
      return p.notReady("Ready state check timed out")
    elif isReadyStateFut.read():
      return p.ready()

    return p.synchronizing()
  except:
    error "exception reading state: " & getCurrentExceptionMsg()
    return p.notReady("State cannot be determined")

proc getLightpushHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.LightpushProtocol)

  if isNil(hm.protocols.lightPush):
    hm.strength[ProtocolName.LightpushProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuLightPushCodec)
  hm.strength[ProtocolName.LightpushProtocol] = peerCount

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLegacyLightpushHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.LegacyLightpushProtocol)

  if isNil(hm.protocols.legacyLightPush):
    hm.strength[ProtocolName.LegacyLightpushProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuLegacyLightPushCodec)
  hm.strength[ProtocolName.LegacyLightpushProtocol] = peerCount

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getFilterHealth(hm: NodeHealthMonitor, relayHealth: HealthStatus): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.FilterProtocol)

  if isNil(hm.protocols.filter):
    hm.strength[ProtocolName.FilterProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuFilterSubscribeCodec)
  hm.strength[ProtocolName.FilterProtocol] = peerCount

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Relay is not ready, filter will not be able to sort out messages")

proc getStoreHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.StoreProtocol)

  if isNil(hm.protocols.store):
    hm.strength[ProtocolName.StoreProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuStoreCodec)
  hm.strength[ProtocolName.StoreProtocol] = peerCount
  return p.ready()

proc getLightpushClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.LightpushClientProtocol)

  if isNil(hm.protocols.lightPushClient):
    hm.strength[ProtocolName.LightpushClientProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuLightPushCodec)
  hm.strength[ProtocolName.LightpushClientProtocol] = peerCount

  if peerCount > 0:
    return p.ready()
  return p.notReady("No Lightpush service peer available yet")

proc getLegacyLightpushClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.LegacyLightpushClientProtocol)

  if isNil(hm.protocols.legacyLightPushClient):
    hm.strength[ProtocolName.LegacyLightpushClientProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuLegacyLightPushCodec)
  hm.strength[ProtocolName.LegacyLightpushClientProtocol] = peerCount

  if peerCount > 0:
    return p.ready()
  return p.notReady("No Lightpush service peer available yet")

proc getFilterClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.FilterClientProtocol)

  if isNil(hm.protocols.filterClient):
    hm.strength[ProtocolName.FilterClientProtocol] = 0
    return p.notMounted()

  if isNil(hm.protocols.relay):
    let edgeRes = RequestEdgeFilterPeerCount.request(hm.brokerCtx)
    if edgeRes.isOk():
      let peerCount = edgeRes.get().peerCount
      if peerCount > 0:
        hm.strength[ProtocolName.FilterClientProtocol] = peerCount
        return p.ready()
    else:
      debug "Failed to request edge filter peer count", error = edgeRes.error
      return p.notReady("Failed to request edge filter peer count: " & edgeRes.error)

  let peerCount = countCapablePeers(hm, WakuFilterSubscribeCodec)
  hm.strength[ProtocolName.FilterClientProtocol] = peerCount

  if peerCount > 0:
    return p.ready()
  return p.notReady("No Filter service peer available yet")

proc getStoreClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.StoreClientProtocol)

  if isNil(hm.protocols.storeClient):
    hm.strength[ProtocolName.StoreClientProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuStoreCodec)
  hm.strength[ProtocolName.StoreClientProtocol] = peerCount

  if peerCount > 0 or not isNil(hm.protocols.store):
    return p.ready()

  return p.notReady(
    "No Store service peer available yet, neither Store service set up for the node"
  )

proc getPeerExchangeHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.PeerExchangeProtocol)

  if isNil(hm.discovery.peerExchange):
    hm.strength[ProtocolName.PeerExchangeProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, WakuPeerExchangeCodec)
  hm.strength[ProtocolName.PeerExchangeProtocol] = peerCount

  return p.ready()

proc getRendezvousHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.RendezvousProtocol)

  if isNil(hm.discovery.rendezvous):
    hm.strength[ProtocolName.RendezvousProtocol] = 0
    return p.notMounted()

  let peerCount = countCapablePeers(hm, RendezVousCodec)
  hm.strength[ProtocolName.RendezvousProtocol] = peerCount
  if peerCount == 0:
    return p.notReady("No Rendezvous peers are available yet")

  return p.ready()

proc hasMixExit(hm: NodeHealthMonitor): bool =
  ## Mirrors `selectMixLightpushPeer`, minus its per-message shard filter.
  ## Returns true if one node in the mix pool is capable of serving lightpush to exit through.
  let pool = hm.protocols.mix.nodePool
  let slotted = hm.peerManager.serviceSlots.getOrDefault(WakuLightPushCodec)
  if not slotted.isNil() and pool.get(slotted.peerId).isSome():
    return true
  let peerStore = hm.switch.peerStore
  return pool.peerIds().anyIt(
      peerStore[ProtoBook][it].contains(WakuLightPushCodec) and pool.get(it).isSome()
    )

proc getMixHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init(ProtocolName.MixProtocol)

  if isNil(hm.protocols.mix):
    hm.strength[ProtocolName.MixProtocol] = 0
    return p.notMounted()

  let poolSize = (if hm.protocols.mix.isNil(): 0
  else: hm.protocols.mix.poolSize())
  hm.strength[ProtocolName.MixProtocol] = poolSize

  # Checked before the pool: discovery cannot fix a hop that the encoder
  # rejects, and every reply path and cover packet fails on it.
  if not hm.protocols.mix.selfHopUsable():
    return p.notReady(
      "This node's announced address is not one mix can route replies to (IPv4 TCP or QUIC-v1)"
    )

  # Same threshold as `mixReady`, so health and the send path agree.
  if poolSize < MinMixPoolSize:
    return p.notReady("Mix pool too small: " & $poolSize & " < " & $MinMixPoolSize)

  if not hm.hasMixExit():
    return p.notReady("No mix pool member serves lightpush to exit through")

  return p.ready()

proc getSyncProtocolHealthInfo*(
    hm: NodeHealthMonitor, protocol: ProtocolName
): ProtocolHealth =
  ## Get ProtocolHealth for a given protocol that can provide it synchronously
  ##
  case protocol
  of ProtocolName.RelayProtocol:
    return hm.getRelayHealth()
  of ProtocolName.StoreProtocol:
    return hm.getStoreHealth()
  of ProtocolName.FilterProtocol:
    return hm.getFilterHealth(hm.getRelayHealth().health)
  of ProtocolName.LightpushProtocol:
    return hm.getLightpushHealth(hm.getRelayHealth().health)
  of ProtocolName.LegacyLightpushProtocol:
    return hm.getLegacyLightpushHealth(hm.getRelayHealth().health)
  of ProtocolName.PeerExchangeProtocol:
    return hm.getPeerExchangeHealth()
  of ProtocolName.RendezvousProtocol:
    return hm.getRendezvousHealth()
  of ProtocolName.MixProtocol:
    return hm.getMixHealth()
  of ProtocolName.StoreClientProtocol:
    return hm.getStoreClientHealth()
  of ProtocolName.FilterClientProtocol:
    return hm.getFilterClientHealth()
  of ProtocolName.LightpushClientProtocol:
    return hm.getLightpushClientHealth()
  of ProtocolName.LegacyLightpushClientProtocol:
    return hm.getLegacyLightpushClientHealth()
  of ProtocolName.RlnRelayProtocol:
    # Could waitFor here but we don't want to block the main thread.
    # Could also return a cached value from a previous check.
    var p = ProtocolHealth.init(protocol)
    return p.notReady("RLN Relay health check is async")
  else:
    var p = ProtocolHealth.init(protocol)
    return p.notMounted()

proc getProtocolHealthInfo*(
    hm: NodeHealthMonitor, protocol: ProtocolName
): Future[ProtocolHealth] {.async.} =
  ## Get ProtocolHealth for a given protocol
  ##
  case protocol
  of ProtocolName.RlnRelayProtocol:
    return await hm.getRlnRelayHealth()
  else:
    return hm.getSyncProtocolHealthInfo(protocol)

proc getSyncAllProtocolHealthInfo(hm: NodeHealthMonitor): seq[ProtocolHealth] =
  ## Get ProtocolHealth for the subset of protocols that can provide it synchronously
  ##
  var protocols: seq[ProtocolHealth] = @[]
  let relayHealth = hm.getRelayHealth()
  protocols.add(relayHealth)

  protocols.add(hm.getLightpushHealth(relayHealth.health))
  protocols.add(hm.getLegacyLightpushHealth(relayHealth.health))
  protocols.add(hm.getFilterHealth(relayHealth.health))
  protocols.add(hm.getStoreHealth())
  protocols.add(hm.getPeerExchangeHealth())
  protocols.add(hm.getRendezvousHealth())
  protocols.add(hm.getMixHealth())

  protocols.add(hm.getLightpushClientHealth())
  protocols.add(hm.getLegacyLightpushClientHealth())
  protocols.add(hm.getStoreClientHealth())
  protocols.add(hm.getFilterClientHealth())
  return protocols

proc getAllProtocolHealthInfo(
    hm: NodeHealthMonitor
): Future[seq[ProtocolHealth]] {.async.} =
  ## Get ProtocolHealth for all protocols
  ##
  var protocols = hm.getSyncAllProtocolHealthInfo()

  let rlnHealth = await hm.getRlnRelayHealth()
  protocols.add(rlnHealth)

  return protocols

proc calculateConnectionState*(
    protocols: seq[ProtocolHealth],
    strength: Table[ProtocolName, int], ## latest connectivity strength (e.g. peer count) for a protocol
    dLowOpt: Opt[int], ## minimum relay peers for Connected status if in Core (Relay) mode
): ConnectionStatus =
  var
    relayCount = 0
    lightpushCount = 0
    filterCount = 0
    storeClientCount = 0

  for p in protocols:
    let kind =
      try:
        parseEnum[ProtocolName](p.protocol)
      except ValueError:
        continue

    if p.health != HealthStatus.READY:
      continue

    let strength = strength.getOrDefault(kind, 0)

    if kind in RelayProtocols:
      relayCount = max(relayCount, strength)
    elif kind in StoreClientProtocols:
      storeClientCount = max(storeClientCount, strength)
    elif kind in LightpushClientProtocols:
      lightpushCount = max(lightpushCount, strength)
    elif kind in FilterClientProtocols:
      filterCount = max(filterCount, strength)

  debug "calculateConnectionState",
    relayCount, storeClientCount, lightpushCount, filterCount

  # Relay connectivity should be a sufficient check in Core mode.
  # "Store peers" are relay peers because incoming messages in
  # the relay are input to the store server.
  # But if Store server (or client, even) is not mounted as well, this logic assumes
  # the user knows what they're doing.

  if dLowOpt.isSome():
    if relayCount >= dLowOpt.get():
      return ConnectionStatus.Connected

  if relayCount > 0:
    return ConnectionStatus.PartiallyConnected

  # No relay connectivity. Relay might not be mounted, or may just have zero peers.
  # Fall back to Edge check in any case to be sure.

  let canSend = lightpushCount > 0
  let canReceive = filterCount > 0
  let canStore = storeClientCount > 0

  let meetsMinimum = canSend and canReceive and canStore

  if not meetsMinimum:
    return ConnectionStatus.Disconnected

  let isEdgeRobust =
    (lightpushCount >= HealthyThreshold) and (filterCount >= HealthyThreshold) and
    (storeClientCount >= HealthyThreshold)

  if isEdgeRobust:
    return ConnectionStatus.Connected

  return ConnectionStatus.PartiallyConnected

proc calculateConnectionState*(hm: NodeHealthMonitor): ConnectionStatus =
  let dLow =
    if isNil(hm.protocols.relay):
      Opt.none(int)
    else:
      Opt.some(hm.protocols.relay.parameters.dLow)
  let status = calculateConnectionState(hm.cachedProtocols, hm.strength, dLow)
  if hm.adjustConnectionStatus.isNil():
    return status
  return hm.adjustConnectionStatus(status, hm.cachedProtocols)

proc getNodeHealthReport*(hm: NodeHealthMonitor): Future[HealthReport] {.async.} =
  ## Get a HealthReport that includes all protocols
  ##
  var report: HealthReport

  if hm.nodeHealth == HealthStatus.INITIALIZING or
      hm.nodeHealth == HealthStatus.SHUTTING_DOWN:
    report.nodeHealth = hm.nodeHealth
    report.connectionStatus = ConnectionStatus.Disconnected
    return report

  if hm.cachedProtocols.len == 0:
    hm.publishProtocolHealth(await hm.getAllProtocolHealthInfo())
    hm.connectionStatus = hm.calculateConnectionState()

  report.nodeHealth =
    if hm.eventLoopLagExceeded: HealthStatus.EVENT_LOOP_LAGGING else: HealthStatus.READY
  report.connectionStatus = hm.connectionStatus
  report.protocolsHealth = hm.cachedProtocols
  return report

proc getSyncNodeHealthReport*(hm: NodeHealthMonitor): HealthReport =
  ## Get a HealthReport that includes the subset of protocols that inform health synchronously
  ##
  var report: HealthReport

  if hm.nodeHealth == HealthStatus.INITIALIZING or
      hm.nodeHealth == HealthStatus.SHUTTING_DOWN:
    report.nodeHealth = hm.nodeHealth
    report.connectionStatus = ConnectionStatus.Disconnected
    return report

  if hm.cachedProtocols.len == 0:
    hm.publishProtocolHealth(hm.getSyncAllProtocolHealthInfo())
    hm.connectionStatus = hm.calculateConnectionState()

  report.nodeHealth =
    if hm.eventLoopLagExceeded: HealthStatus.EVENT_LOOP_LAGGING else: HealthStatus.READY
  report.connectionStatus = hm.connectionStatus
  report.protocolsHealth = hm.cachedProtocols
  return report

proc onRelayMsg(
    hm: NodeHealthMonitor, peer: PubSubPeer, msg: var RPCMsg
) {.gcsafe, raises: [].} =
  ## Inspect Relay events for health-update relevance in Core (Relay) mode.
  ##
  ## For Core (Relay) mode, the connectivity health state is mostly determined
  ## by the relay protocol state (it is the dominant factor), and we know
  ## that a peer Relay can only affect this Relay's health if there is a
  ## subscription change or a mesh (GRAFT/PRUNE) change.
  ##

  if msg.subscriptions.len == 0:
    if msg.control.isNone():
      return
    let ctrl = msg.control.get()
    if ctrl.graft.len == 0 and ctrl.prune.len == 0:
      return

  hm.healthUpdateEvent.fire()

proc healthLoop(hm: NodeHealthMonitor) {.async.} =
  ## Re-evaluate the global health state of the node when notified of a potential change,
  ## and call back the application if an actual change from the last notified state happened.
  info "Health monitor loop start"
  while true:
    try:
      await hm.healthUpdateEvent.wait()
      hm.healthUpdateEvent.clear()

      hm.publishProtocolHealth(await hm.getAllProtocolHealthInfo())

      # A `MixPubKeyBook` change wakes this loop, so the gauge follows the pool
      # as it fills, with no traffic. The loop publishes it, so a health read, as
      # from the REST endpoint, has no side effect.
      if not isNil(hm.protocols.mix):
        updatePoolSize(hm.strength.getOrDefault(ProtocolName.MixProtocol, 0))

      let newConnectionStatus = hm.calculateConnectionState()

      if newConnectionStatus != hm.connectionStatus:
        debug "connectionStatus change",
          oldstatus = hm.connectionStatus, newstatus = newConnectionStatus

        hm.connectionStatus = newConnectionStatus

        EventConnectionStatusChange.emit(hm.brokerCtx, newConnectionStatus)

        if not isNil(hm.onConnectionStatusChange):
          await hm.onConnectionStatusChange(newConnectionStatus)
    except CancelledError:
      break
    except Exception as e:
      error "HealthMonitor: error in update loop", error = e.msg

    # safety cooldown to protect from edge cases
    await sleepAsync(100.milliseconds)

  info "Health monitor loop end"

proc selectRandomPeersForKeepalive(
    hm: NodeHealthMonitor, outPeers: seq[PeerId], numRandomPeers: int
): Future[seq[PeerId]] {.async.} =
  ## Select peers for random keepalive, prioritizing mesh peers

  if isNil(hm.protocols.relay):
    return selectRandomPeers(outPeers, numRandomPeers)

  let meshPeers = hm.protocols.relay.getPeersInMesh().valueOr:
    debug "Failed getting peers in mesh for ping", error = error
    # Fallback to random selection from all outgoing peers
    return selectRandomPeers(outPeers, numRandomPeers)

  trace "Mesh peers for keepalive", meshPeers = meshPeers

  # Get non-mesh peers and shuffle them
  var nonMeshPeers = outPeers.filterIt(it notin meshPeers)
  shuffle(nonMeshPeers)

  # Combine mesh peers + random non-mesh peers up to numRandomPeers total
  let numNonMeshPeers = max(0, numRandomPeers - len(meshPeers))
  let selectedNonMeshPeers = nonMeshPeers[0 ..< min(len(nonMeshPeers), numNonMeshPeers)]

  let selectedPeers = meshPeers & selectedNonMeshPeers
  trace "Selected peers for keepalive", selected = selectedPeers
  return selectedPeers

proc keepAliveLoop(
    hm: NodeHealthMonitor,
    randomPeersKeepalive: chronos.Duration,
    allPeersKeepAlive: chronos.Duration,
    numRandomPeers = 10,
) {.async.} =
  # Calculate how many random peer cycles before pinging all peers
  let randomToAllRatio =
    int(allPeersKeepAlive.seconds() / randomPeersKeepalive.seconds())
  var countdownToPingAll = max(0, randomToAllRatio - 1)

  # Sleep detection configuration
  let sleepDetectionInterval = 3 * randomPeersKeepalive

  # Failure tracking
  var consecutiveIterationFailures = 0
  const maxAllowedConsecutiveFailures = 2

  var lastTimeExecuted = Moment.now()

  while true:
    trace "Running keepalive loop"
    await sleepAsync(randomPeersKeepalive)

    if not hm.isStarted():
      continue

    let currentTime = Moment.now()

    # Check for sleep detection
    if currentTime - lastTimeExecuted > sleepDetectionInterval:
      warn "Keep alive hasn't been executed recently. Killing all connections"
      await hm.peerManager.disconnectAllPeers()
      lastTimeExecuted = currentTime
      consecutiveIterationFailures = 0
      continue

    # Check for consecutive failures
    if consecutiveIterationFailures > maxAllowedConsecutiveFailures:
      warn "Too many consecutive ping failures, node likely disconnected. Killing all connections",
        consecutiveIterationFailures, maxAllowedConsecutiveFailures
      await hm.peerManager.disconnectAllPeers()
      consecutiveIterationFailures = 0
      lastTimeExecuted = currentTime
      continue

    # Determine which peers to ping
    let outPeers = hm.peerManager.connectedPeers()[1]
    let peersToPing =
      if countdownToPingAll > 0:
        await selectRandomPeersForKeepalive(hm, outPeers, numRandomPeers)
      else:
        outPeers

    let numPeersToPing = len(peersToPing)

    if countdownToPingAll > 0:
      trace "Pinging random peers",
        count = numPeersToPing, countdownToPingAll = countdownToPingAll
      countdownToPingAll.dec()
    else:
      trace "Pinging all peers", count = numPeersToPing
      countdownToPingAll = max(0, randomToAllRatio - 1)

    # Execute keepalive pings
    let successfulPings =
      await parallelPings(hm.peerManager, hm.protocols.libp2pPing, peersToPing)

    if successfulPings != numPeersToPing:
      logos_delivery_node_errors.inc(
        amount = numPeersToPing - successfulPings, labelValues = ["keep_alive_failure"]
      )

    trace "Keepalive results",
      attemptedPings = numPeersToPing, successfulPings = successfulPings

    # Update failure tracking
    if numPeersToPing > 0 and successfulPings == 0:
      consecutiveIterationFailures.inc()
      debug "All pings failed", consecutiveFailures = consecutiveIterationFailures
    else:
      consecutiveIterationFailures = 0

    lastTimeExecuted = currentTime

# 2 minutes default - 20% of the default chronosstream timeout duration
proc startKeepalive*(
    hm: NodeHealthMonitor,
    randomPeersKeepalive = 10.seconds,
    allPeersKeepalive = 2.minutes,
): Result[void, string] =
  # Validate input parameters
  if randomPeersKeepalive.isZero() or allPeersKeepAlive.isZero():
    error "startKeepalive: allPeersKeepAlive and randomPeersKeepalive must be greater than 0",
      randomPeersKeepalive = $randomPeersKeepalive,
      allPeersKeepAlive = $allPeersKeepAlive
    return err(
      "startKeepalive: allPeersKeepAlive and randomPeersKeepalive must be greater than 0"
    )

  if allPeersKeepAlive < randomPeersKeepalive:
    error "startKeepalive: allPeersKeepAlive can't be less than randomPeersKeepalive",
      allPeersKeepAlive = $allPeersKeepAlive,
      randomPeersKeepalive = $randomPeersKeepalive
    return
      err("startKeepalive: allPeersKeepAlive can't be less than randomPeersKeepalive")

  info "starting keepalive",
    randomPeersKeepalive = randomPeersKeepalive, allPeersKeepalive = allPeersKeepalive

  hm.keepAliveFut = hm.keepAliveLoop(randomPeersKeepalive, allPeersKeepalive)
  return ok()

proc setOverallHealth*(hm: NodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health

proc onMixPoolChange(hm: NodeHealthMonitor) =
  if hm.protocols.mix.isNil() or hm.healthUpdateEvent.isNil():
    return
  hm.healthUpdateEvent.fire()

proc startHealthMonitor*(hm: NodeHealthMonitor): Result[void, string] =
  hm.onlineMonitor.startOnlineMonitor()

  if isNil(hm.peerManager):
    return err("startHealthMonitor: no node peerManager to monitor")

  if not isNil(hm.protocols.relay):
    hm.relayObserver = PubSubObserver(
      onRecv: proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].} =
        hm.onRelayMsg(peer, msgs)
    )
    hm.protocols.relay.addObserver(hm.relayObserver)

  hm.peerEventListener = WakuPeerEvent.listen(
    hm.brokerCtx,
    proc(evt: WakuPeerEvent): Future[void] {.async: (raises: []), gcsafe.} =
      ## Recompute health on any peer changing anything (join, leave, identify, metadata update)
      hm.healthUpdateEvent.fire(),
  ).valueOr:
    return err("Failed to subscribe to peer events: " & error)

  hm.shardHealthListener = EventShardTopicHealthChange.listen(
    hm.brokerCtx,
    proc(
        evt: EventShardTopicHealthChange
    ): Future[void] {.async: (raises: []), gcsafe.} =
      hm.healthUpdateEvent.fire(),
  ).valueOr:
    return err("Failed to subscribe to shard health events: " & error)

  hm.healthUpdateEvent = newAsyncEvent()
  hm.healthUpdateEvent.fire()

  hm.healthLoopFut = hm.healthLoop()
  hm.eventLoopMonitorFut = eventLoopMonitorLoop(
    proc(lagTooHigh: bool) {.gcsafe, raises: [].} =
      hm.eventLoopLagExceeded = lagTooHigh
      hm.healthUpdateEvent.fire()
  )

  hm.startKeepalive().isOkOr:
    return err("startHealthMonitor: failed starting keep alive: " & error)

  return ok()

proc stopHealthMonitor*(hm: NodeHealthMonitor) {.async.} =
  if not isNil(hm.onlineMonitor):
    await hm.onlineMonitor.stopOnlineMonitor()

  if not isNil(hm.keepAliveFut):
    await hm.keepAliveFut.cancelAndWait()

  if not isNil(hm.healthLoopFut):
    await hm.healthLoopFut.cancelAndWait()

  if not isNil(hm.eventLoopMonitorFut):
    await hm.eventLoopMonitorFut.cancelAndWait()

  await WakuPeerEvent.dropListener(hm.brokerCtx, hm.peerEventListener)
  await EventShardTopicHealthChange.dropListener(hm.brokerCtx, hm.shardHealthListener)

  if not isNil(hm.protocols.relay) and not isNil(hm.relayObserver):
    hm.protocols.relay.removeObserver(hm.relayObserver)

proc new*(
    T: type NodeHealthMonitor,
    protocols: Protocols,
    discovery: Discovery,
    peerManager: PeerManager,
    switch: Switch,
    brokerCtx: BrokerContext,
    isStarted: proc(): bool {.gcsafe, raises: [].},
    dnsNameServers = @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
): T =
  let om = OnlineMonitor.init(dnsNameServers)
  om.setPeerStoreToOnlineMonitor(switch.peerStore)
  om.addOnlineStateObserver(peerManager.getOnlineStateObserver())
  let hm = T(
    nodeHealth: INITIALIZING,
    protocols: protocols,
    discovery: discovery,
    peerManager: peerManager,
    switch: switch,
    brokerCtx: brokerCtx,
    isStarted: isStarted,
    onlineMonitor: om,
    connectionStatus: ConnectionStatus.Disconnected,
    strength: initTable[ProtocolName, int](),
  )
  # Mix peers are learnt from discovery without any peer event, so without this
  # a filled (or drained) pool would wait for an unrelated trigger to show up.
  switch.peerStore[MixPubKeyBook].addHandler(
    proc(peerId: PeerId) {.gcsafe, raises: [].} =
      hm.onMixPoolChange()
  )
  # ENR discovery and identify learn a pool peer's lightpush (its exit role)
  # through ProtoBook alone, without writing its mix key.
  switch.peerStore[ProtoBook].addHandler(
    proc(peerId: PeerId) {.gcsafe, raises: [].} =
      if peerId in switch.peerStore[MixPubKeyBook]:
        hm.onMixPoolChange()
  )
  return hm
