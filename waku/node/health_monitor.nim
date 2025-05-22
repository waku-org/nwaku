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

const FutIsReadyTimout = 5.seconds

proc getRelayHealth(hm: WakuNodeHealthMonitor): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuRelay == nil:
    return HealthStatus.NOT_MOUNTED

  let relayPeers = hm.node
    .get().wakuRelay
    .getConnectedPubSubPeers(pubsubTopic = "").valueOr:
      return HealthStatus.NOT_READY

  if relayPeers.len() == 0:
    return HealthStatus.NOT_READY

  return HealthStatus.READY

proc getRlnRelayHealth(hm: WakuNodeHealthMonitor): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuRlnRelay == nil:
    return HealthStatus.NOT_MOUNTED

  let isReadyStateFut = hm.node.get().wakuRlnRelay.isReady()
  if not await isReadyStateFut.withTimeout(FutIsReadyTimout):
    return HealthStatus.NOT_READY

  try:
    if not isReadyStateFut.completed():
      return HealthStatus.NOT_READY
    elif isReadyStateFut.read():
      return HealthStatus.READY

    return HealthStatus.SYNCHRONIZING
  except:
    error "exception reading state: " & getCurrentExceptionMsg()
    return HealthStatus.NOT_READY

proc getLightpushHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuLightPush == nil:
    return HealthStatus.NOT_MOUNTED

  if relayHealth == HealthStatus.READY:
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getLightpushClientHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuLightpushClient == nil:
    return HealthStatus.NOT_MOUNTED

  if (hm.node.get().wakuLightPush != nil and relayHealth == HealthStatus.READY) or
      hm.node.get().peerManager.selectPeer(WakuLightPushCodec).isSome():
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getLegacyLightpushHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuLegacyLightPush == nil:
    return HealthStatus.NOT_MOUNTED

  if relayHealth == HealthStatus.READY:
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getLegacyLightpushClientHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuLegacyLightpushClient == nil:
    return HealthStatus.NOT_MOUNTED

  if (hm.node.get().wakuLegacyLightPush != nil and relayHealth == HealthStatus.READY) or
      hm.node.get().peerManager.selectPeer(WakuLegacyLightPushCodec).isSome():
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getFilterHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuFilter == nil:
    return HealthStatus.NOT_MOUNTED

  if relayHealth == HealthStatus.READY:
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getFilterClientHealth(
    hm: WakuNodeHealthMonitor, relayHealth: HealthStatus
): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuFilterClient == nil:
    return HealthStatus.NOT_MOUNTED

  if hm.node.get().peerManager.selectPeer(WakuFilterSubscribeCodec).isSome():
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getStoreHealth(hm: WakuNodeHealthMonitor): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuStore == nil:
    return HealthStatus.NOT_MOUNTED

  return HealthStatus.READY

proc getStoreClientHealth(hm: WakuNodeHealthMonitor): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuStoreClient == nil:
    return HealthStatus.NOT_MOUNTED

  if hm.node.get().peerManager.selectPeer(WakuStoreCodec).isSome() or
      hm.node.get().wakuStore != nil:
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getLegacyStoreHealth(hm: WakuNodeHealthMonitor): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuLegacyStore == nil:
    return HealthStatus.NOT_MOUNTED

  return HealthStatus.READY

proc getLegacyStoreClientHealth(
    hm: WakuNodeHealthMonitor
): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuLegacyStoreClient == nil:
    return HealthStatus.NOT_MOUNTED

  if hm.node.get().peerManager.selectPeer(WakuLegacyStoreCodec).isSome() or
      hm.node.get().wakuLegacyStore != nil:
    return HealthStatus.READY

  return HealthStatus.NOT_READY

proc getPeerExchangeHealth(hm: WakuNodeHealthMonitor): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuPeerExchange == nil:
    return HealthStatus.NOT_MOUNTED

  return HealthStatus.READY

proc getRendezvousHealth(hm: WakuNodeHealthMonitor): Future[HealthStatus] {.async.} =
  if hm.node.get().wakuRendezvous == nil:
    return HealthStatus.NOT_MOUNTED

  if hm.node.get().peerManager.switch.peerStore.peers(RendezVousCodec).len() == 0:
    return HealthStatus.NOT_READY

  return HealthStatus.READY

proc getNodeHealthReport*(hm: WakuNodeHealthMonitor): Future[HealthReport] {.async.} =
  result.nodeHealth = hm.nodeHealth

  if hm.node.isSome():
    let relayHealth = await hm.getRelayHealth()
    result.protocolsHealth.add(ProtocolHealth(protocol: "Relay", health: relayHealth))
    result.protocolsHealth.add(
      ProtocolHealth(protocol: "Rln Relay", health: await hm.getRlnRelayHealth())
    )
    result.protocolsHealth.add(
      ProtocolHealth(
        protocol: "Lightpush v3", health: await hm.getLightpushHealth(relayHealth)
      )
    )
    result.protocolsHealth.add(
      ProtocolHealth(
        protocol: "Lightpush Legacy",
        health: await hm.getLegacyLightpushHealth(relayHealth),
      )
    )
    result.protocolsHealth.add(
      ProtocolHealth(protocol: "Filter", health: await hm.getFilterHealth(relayHealth))
    )
    result.protocolsHealth.add(
      ProtocolHealth(protocol: "Store", health: await hm.getStoreHealth())
    )
    result.protocolsHealth.add(
      ProtocolHealth(protocol: "Legacy Store", health: await hm.getLegacyStoreHealth())
    )
    result.protocolsHealth.add(
      ProtocolHealth(
        protocol: "Peer Exchange", health: await hm.getPeerExchangeHealth()
      )
    )
    result.protocolsHealth.add(
      ProtocolHealth(protocol: "Rendezvous", health: await hm.getRendezvousHealth())
    )
    result.protocolsHealth.add(
      ProtocolHealth(
        protocol: "Lightpush Client",
        health: await hm.getLightpushClientHealth(relayHealth),
      )
    )
    result.protocolsHealth.add(
      ProtocolHealth(
        protocol: "Legacy Lightpush Client",
        health: await hm.getLegacyLightpushClientHealth(relayHealth),
      )
    )
    result.protocolsHealth.add(
      ProtocolHealth(protocol: "Store Client", health: await hm.getStoreClientHealth())
    )
    result.protocolsHealth.add(
      ProtocolHealth(
        protocol: "Legacy Store Client", health: await hm.getLegacyStoreClientHealth()
      )
    )
    result.protocolsHealth.add(
      ProtocolHealth(
        protocol: "Filter Client", health: await hm.getFilterClientHealth(relayHealth)
      )
    )

  return result

proc setNode*(hm: WakuNodeHealthMonitor, node: WakuNode) =
  hm.node = some(node)

proc setOverallHealth*(hm: WakuNodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health
