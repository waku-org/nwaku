{.push raises: [].}

import std/[options, sets], chronos, libp2p/protocols/rendezvous

import waku_node, ../waku_rln_relay, ../waku_relay, ./peer_manager

type
  HealthStatus* = enum
    INITIALIZING
    SYNCHRONIZING
    READY
    NOT_READY
    NOT_MOUNTED
    SHUTTING_DOWN

  ProtocolHealth* = object
    protocol*: string
    health*: HealthStatus
    desc*: Option[string]

  HealthReport* = object
    nodeHealth*: HealthStatus
    protocolsHealth*: seq[ProtocolHealth]

  WakuNodeHealthMonitor* = ref object
    nodeHealth: HealthStatus
    node: Option[WakuNode]

proc `$`*(t: HealthStatus): string =
  result =
    case t
    of INITIALIZING: "Initializing"
    of SYNCHRONIZING: "Synchronizing"
    of READY: "Ready"
    of NOT_READY: "Not Ready"
    of NOT_MOUNTED: "Not Mounted"
    of SHUTTING_DOWN: "Shutting Down"

proc init*(
    t: typedesc[HealthStatus], strRep: string
): HealthStatus {.raises: [ValueError].} =
  case strRep
  of "Initializing":
    return HealthStatus.INITIALIZING
  of "Synchronizing":
    return HealthStatus.SYNCHRONIZING
  of "Ready":
    return HealthStatus.READY
  of "Not Ready":
    return HealthStatus.NOT_READY
  of "Not Mounted":
    return HealthStatus.NOT_MOUNTED
  of "Shutting Down":
    return HealthStatus.SHUTTING_DOWN
  else:
    raise newException(ValueError, "Invalid HealthStatus string representation")

proc init*(p: typedesc[ProtocolHealth], protocol: string): ProtocolHealth =
  result.protocol = protocol
  result.health = HealthStatus.NOT_MOUNTED
  result.desc = none[string]()
  return result

proc notReady(p: var ProtocolHealth, desc: string): ProtocolHealth =
  p.health = HealthStatus.NOT_READY
  p.desc = some(desc)
  return p

proc ready(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.READY
  p.desc = none[string]()
  return p

proc notMounted(p: var ProtocolHealth): ProtocolHealth =
    p.health = HealthStatus.NOT_MOUNTED
    p.desc = none[string]()
    return p

proc synchronizing(p: var ProtocolHealth): ProtocolHealth =
    p.health = HealthStatus.SYNCHRONIZING
    p.desc = none[string]()
    return p

proc initializing(p: var ProtocolHealth): ProtocolHealth =
    p.health = HealthStatus.INITIALIZING
    p.desc = none[string]()
    return p

proc shuttingDown(p: var ProtocolHealth): ProtocolHealth =
    p.health = HealthStatus.SHUTTING_DOWN
    p.desc = none[string]()
    return p

const FutIsReadyTimout = 5.seconds

proc getRelayHealth(hm: WakuNodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Relay")
  if hm.node.get().wakuRelay == nil:
    return p.notMounted()

  let relayPeers = hm.node
    .get().wakuRelay
    .getConnectedPubSubPeers(pubsubTopic = "").valueOr:
      return p.notMounted()

  if relayPeers.len() == 0:
    return p.notReady("No connected peers")

  return p.ready()

proc getRlnRelayHealth(hm: WakuNodeHealthMonitor): Future[ProtocolHealth] {.async.} =
  var p = ProtocolHealth.init("Rln Relay")
  if hm.node.get().wakuRlnRelay == nil:
    return p.notMounted()

  let isReadyStateFut = hm.node.get().wakuRlnRelay.isReady()
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
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Lightpush")
  if hm.node.get().wakuLightPush == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLightpushClientHealth(
   hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Lightpush Client")
  if hm.node.get().wakuLightpushClient == nil:
    return p.notMounted()

  let selfServiceAvailable = hm.node.get().wakuLightPush != nil and
    relayHealth == HealthStatus.READY
  let servicePeerAvailable =
    hm.node.get().peerManager.selectPeer(WakuLightPushCodec).isSome()

  if selfServiceAvailable or servicePeerAvailable:
    return p.ready()

  return p.notReady("No Lightpush service peer available yet")

proc getLegacyLightpushHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Lightpush")
  if hm.node.get().wakuLegacyLightPush == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLegacyLightpushClientHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Lightpush Client")
  if hm.node.get().wakuLegacyLightpushClient == nil:
    return p.notMounted()

  if (hm.node.get().wakuLegacyLightPush != nil and relayHealth == HealthStatus.READY) or
      hm.node.get().peerManager.selectPeer(WakuLegacyLightPushCodec).isSome():
    return p.ready()

  return p.notReady("No Lightpush service peer available yet")

proc getFilterHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Filter")
  if hm.node.get().wakuFilter == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Relay is not ready, filter will not be able to sort out messages")

proc getFilterClientHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Filter Client")
  if hm.node.get().wakuFilterClient == nil:
    return p.notMounted()

  if hm.node.get().peerManager.selectPeer(WakuFilterSubscribeCodec).isSome():
    return p.ready()

  return p.notReady("No Filter service peer available yet")

proc getStoreHealth(hm: WakuNodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Store")
  if hm.node.get().wakuStore == nil:
    return p.notMounted()

  return p.ready()

proc getStoreClientHealth(hm: WakuNodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Store Client")
  if hm.node.get().wakuStoreClient == nil:
    return p.notMounted()

  if hm.node.get().peerManager.selectPeer(WakuStoreCodec).isSome() or
      hm.node.get().wakuStore != nil:
    return p.ready()

  return p.notReady("No Store service peer available yet, neither Store service set up for the node")

proc getLegacyStoreHealth(hm: WakuNodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Store")
  if hm.node.get().wakuLegacyStore == nil:
    return p.notMounted()

  return p.ready()

proc getLegacyStoreClientHealth(
    hm: WakuNodeHealthMonitor
): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Store Client")
  if hm.node.get().wakuLegacyStoreClient == nil:
    return p.notMounted()

  if hm.node.get().peerManager.selectPeer(WakuLegacyStoreCodec).isSome() or
      hm.node.get().wakuLegacyStore != nil:
    return p.ready()

  return p.notReady("No Legacy Store service peers are available yet, neither Store service set up for the node")

proc getPeerExchangeHealth(hm: WakuNodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Peer Exchange")
  if hm.node.get().wakuPeerExchange == nil:
    return p.notMounted()

  return p.ready()

proc getRendezvousHealth(hm: WakuNodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Rendezvous")
  if hm.node.get().wakuRendezvous == nil:
    return p.notMounted()

  if hm.node.get().peerManager.switch.peerStore.peers(RendezVousCodec).len() == 0:
    return p.notReady("No Rendezvous peers are available yet")

  return p.ready()


proc getNodeHealthReport*(hm: WakuNodeHealthMonitor): Future[HealthReport] {.async.} =
  result.nodeHealth = hm.nodeHealth

  if hm.node.isSome():
    let relayHealth = hm.getRelayHealth()
    result.protocolsHealth.add(relayHealth)
    result.protocolsHealth.add(await hm.getRlnRelayHealth())
    result.protocolsHealth.add(hm.getLightpushHealth(relayHealth.health))
    result.protocolsHealth.add(hm.getLegacyLightpushHealth(relayHealth.health))
    result.protocolsHealth.add(hm.getFilterHealth(relayHealth.health))
    result.protocolsHealth.add(hm.getStoreHealth())
    result.protocolsHealth.add(hm.getLegacyStoreHealth())
    result.protocolsHealth.add(hm.getPeerExchangeHealth())
    result.protocolsHealth.add(hm.getRendezvousHealth())

    result.protocolsHealth.add(hm.getLightpushClientHealth(relayHealth.health))
    result.protocolsHealth.add(hm.getLegacyLightpushClientHealth(relayHealth.health))
    result.protocolsHealth.add(hm.getStoreClientHealth())
    result.protocolsHealth.add(hm.getLegacyStoreClientHealth())
    result.protocolsHealth.add(hm.getFilterClientHealth(relayHealth.health))
  return result

proc setNode*(hm: WakuNodeHealthMonitor, node: WakuNode) =
  hm.node = some(node)

proc setOverallHealth*(hm: WakuNodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health
