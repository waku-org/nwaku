when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options], chronos

import waku_node, ../waku_rln_relay

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

proc getNodeHealthReport*(hm: WakuNodeHealthMonitor): Future[HealthReport] {.async.} =
  result.nodeHealth = hm.nodeHealth

  if hm.node.isSome() and hm.node.get().wakuRlnRelay != nil:
    let getRlnRelayHealth = proc(): Future[HealthStatus] {.async.} =
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

    result.protocolsHealth.add(
      ProtocolHealth(protocol: "Rln Relay", health: await getRlnRelayHealth())
    )

proc setNode*(hm: WakuNodeHealthMonitor, node: WakuNode) =
  hm.node = some(node)

proc setOverallHealth*(hm: WakuNodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health
