when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options, sequtils, strutils, tables], chronos

import waku_node, ../waku_rln_relay

type
  HealthStatus* = enum
    INITIALIZING
    SYNCHRONIZING
    READY
    NOT_READY
    NOT_MOUNTED
    SHUTTING_DOWN

  HealtReport* = object
    nodeHealth*: HealthStatus
    protocolHealth*: Table[string, HealthStatus]

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

const FutIsReadyTimout = 5.seconds

proc getNodeHealthReport*(hm: WakuNodeHealthMonitor): Future[HealtReport] {.async.} =
  result.nodeHealth = hm.nodeHealth

  if hm.node.isSome(): ## and not hm.node.get().wakuRlnRelay == nil:
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

    result.protocolHealth["Rln Relay"] = await getRlnRelayHealth()

proc setNode*(hm: WakuNodeHealthMonitor, node: WakuNode) =
  hm.node = some(node)

proc setOverallHealth*(hm: WakuNodeHealthMonitor, health: HealthStatus) =
  hm.nodeHealth = health
