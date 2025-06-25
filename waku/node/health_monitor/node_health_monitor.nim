{.push raises: [].}

import std/[options, sets, strformat], chronos, chronicles, libp2p/protocols/rendezvous

import
  ../waku_node,
  ../../waku_rln_relay,
  ../../waku_relay,
  ../peer_manager,
  ./online_monitor,
  ./health_status,
  ./protocol_health

## This module is aimed to check the state of the "self" Waku Node

type
  HealthReport* = object
    nodeHealth*: HealthStatus
    protocolsHealth*: seq[ProtocolHealth]

  NodeHealthMonitor* = ref object
    nodeHealth: HealthStatus
    node: WakuNode
    onlineMonitor*: OnlineMonitor
    keepAliveFut: Future[void]

template checkWakuNodeNotNil(node: WakuNode, p: ProtocolHealth): untyped =
  if node.isNil():
    warn "WakuNode is not set, cannot check health", protocol_health_instance = $p
    return p.notMounted()

proc getRelayHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Relay")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuRelay == nil:
    return p.notMounted()

  let relayPeers = hm.node.wakuRelay.getConnectedPubSubPeers(pubsubTopic = "").valueOr:
    return p.notMounted()

  if relayPeers.len() == 0:
    return p.notReady("No connected peers")

  return p.ready()

proc getRlnRelayHealth(hm: NodeHealthMonitor): Future[ProtocolHealth] {.async.} =
  var p = ProtocolHealth.init("Rln Relay")
  if hm.node.isNil():
    warn "WakuNode is not set, cannot check health", protocol_health_instance = $p
    return p.notMounted()

  if hm.node.wakuRlnRelay.isNil():
    return p.notMounted()

  const FutIsReadyTimout = 5.seconds

  let isReadyStateFut = hm.node.wakuRlnRelay.isReady()
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
  var p = ProtocolHealth.init("Lightpush")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLightPush == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLightpushClientHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Lightpush Client")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLightpushClient == nil:
    return p.notMounted()

  let selfServiceAvailable =
    hm.node.wakuLightPush != nil and relayHealth == HealthStatus.READY
  let servicePeerAvailable = hm.node.peerManager.selectPeer(WakuLightPushCodec).isSome()

  if selfServiceAvailable or servicePeerAvailable:
    return p.ready()

  return p.notReady("No Lightpush service peer available yet")

proc getLegacyLightpushHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Lightpush")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLegacyLightPush == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Node has no relay peers to fullfill push requests")

proc getLegacyLightpushClientHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Lightpush Client")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLegacyLightpushClient == nil:
    return p.notMounted()

  if (hm.node.wakuLegacyLightPush != nil and relayHealth == HealthStatus.READY) or
      hm.node.peerManager.selectPeer(WakuLegacyLightPushCodec).isSome():
    return p.ready()

  return p.notReady("No Lightpush service peer available yet")

proc getFilterHealth(hm: NodeHealthMonitor, relayHealth: HealthStatus): ProtocolHealth =
  var p = ProtocolHealth.init("Filter")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuFilter == nil:
    return p.notMounted()

  if relayHealth == HealthStatus.READY:
    return p.ready()

  return p.notReady("Relay is not ready, filter will not be able to sort out messages")

proc getFilterClientHealth(
    hm: NodeHealthMonitor, relayHealth: HealthStatus
): ProtocolHealth =
  var p = ProtocolHealth.init("Filter Client")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuFilterClient == nil:
    return p.notMounted()

  if hm.node.peerManager.selectPeer(WakuFilterSubscribeCodec).isSome():
    return p.ready()

  return p.notReady("No Filter service peer available yet")

proc getStoreHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Store")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuStore == nil:
    return p.notMounted()

  return p.ready()

proc getStoreClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Store Client")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuStoreClient == nil:
    return p.notMounted()

  if hm.node.peerManager.selectPeer(WakuStoreCodec).isSome() or hm.node.wakuStore != nil:
    return p.ready()

  return p.notReady(
    "No Store service peer available yet, neither Store service set up for the node"
  )

proc getLegacyStoreHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Store")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLegacyStore == nil:
    return p.notMounted()

  return p.ready()

proc getLegacyStoreClientHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Legacy Store Client")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuLegacyStoreClient == nil:
    return p.notMounted()

  if hm.node.peerManager.selectPeer(WakuLegacyStoreCodec).isSome() or
      hm.node.wakuLegacyStore != nil:
    return p.ready()

  return p.notReady(
    "No Legacy Store service peers are available yet, neither Store service set up for the node"
  )

proc getPeerExchangeHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Peer Exchange")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuPeerExchange == nil:
    return p.notMounted()

  return p.ready()

proc getRendezvousHealth(hm: NodeHealthMonitor): ProtocolHealth =
  var p = ProtocolHealth.init("Rendezvous")
  checkWakuNodeNotNil(hm.node, p)

  if hm.node.wakuRendezvous == nil:
    return p.notMounted()

  if hm.node.peerManager.switch.peerStore.peers(RendezVousCodec).len() == 0:
    return p.notReady("No Rendezvous peers are available yet")

  return p.ready()

# 2 minutes default - 20% of the default chronosstream timeout duration
proc startKeepalive(
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

  hm.keepAliveFut = hm.node.keepaliveLoop(randomPeersKeepalive, allPeersKeepalive)
  return ok()

proc getNodeHealthReport*(hm: NodeHealthMonitor): Future[HealthReport] {.async.} =
  var report: HealthReport
  report.nodeHealth = hm.nodeHealth

  if not hm.node.isNil():
    let relayHealth = hm.getRelayHealth()
    report.protocolsHealth.add(relayHealth)
    report.protocolsHealth.add(await hm.getRlnRelayHealth())
    report.protocolsHealth.add(hm.getLightpushHealth(relayHealth.health))
    report.protocolsHealth.add(hm.getLegacyLightpushHealth(relayHealth.health))
    report.protocolsHealth.add(hm.getFilterHealth(relayHealth.health))
    report.protocolsHealth.add(hm.getStoreHealth())
    report.protocolsHealth.add(hm.getLegacyStoreHealth())
    report.protocolsHealth.add(hm.getPeerExchangeHealth())
    report.protocolsHealth.add(hm.getRendezvousHealth())

    report.protocolsHealth.add(hm.getLightpushClientHealth(relayHealth.health))
    report.protocolsHealth.add(hm.getLegacyLightpushClientHealth(relayHealth.health))
    report.protocolsHealth.add(hm.getStoreClientHealth())
    report.protocolsHealth.add(hm.getLegacyStoreClientHealth())
    report.protocolsHealth.add(hm.getFilterClientHealth(relayHealth.health))
  return report

proc setNodeToHealthMonitor*(hm: NodeHealthMonitor, node: WakuNode) =
  hm.node = node

proc setOverallHealth*(hm: NodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health

proc startHealthMonitor*(hm: NodeHealthMonitor): Result[void, string] =
  hm.onlineMonitor.startOnlineMonitor()
  hm.startKeepalive().isOkOr:
    return err("startHealthMonitor: failed starting keep alive: " & error)
  return ok()

proc stopHealthMonitor*(hm: NodeHealthMonitor) {.async.} =
  await hm.onlineMonitor.stopOnlineMonitor()
  await hm.keepAliveFut.cancelAndWait()

proc new*(
    T: type NodeHealthMonitor,
    dnsNameServers = @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
): T =
  T(
    nodeHealth: INITIALIZING,
    node: nil,
    onlineMonitor: OnlineMonitor.init(dnsNameServers),
  )
