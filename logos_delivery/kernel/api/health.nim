## Waku layer API — health / connectivity.
{.push raises: [].}

import results, chronos

import logos_delivery/kernel/kernel_lifecycle
import
  logos_delivery/kernel/[
    node/health_monitor/node_health_monitor,
    node/health_monitor/protocol_health,
    node/health_monitor/online_monitor,
    node/health_monitor/connection_status,
    node/health_monitor/health_report,
  ]

export protocol_health

proc isOnline*(self: Kernel): Future[Result[bool, string]] {.async.} =
  try:
    return ok(self.healthMonitor.onlineMonitor.amIOnline())
  except CatchableError as e:
    return err(e.msg)

proc getConnectionStatus*(
    self: Kernel
): Future[Result[ConnectionStatus, string]] {.async.} =
  ## The status `EventConnectionStatusChange` last reported, or would report
  ## now. `Disconnected` while the node is not started.
  if self.healthMonitor.isNil():
    return err("health monitor is not initialized")
  try:
    return ok(self.healthMonitor.getSyncNodeHealthReport().connectionStatus)
  except CatchableError as e:
    return err(e.msg)

proc setConnectionStatusAdjuster*(self: Kernel, adjuster: ConnectionStatusAdjuster) =
  ## Lets an upper layer tighten the connection status; call before start.
  if self.healthMonitor.isNil():
    return
  self.healthMonitor.adjustConnectionStatus = adjuster

func reportedProtocolHealth*(self: Kernel, protocol: WakuProtocol): ProtocolHealth =
  ## The record the health monitor stored for `protocol` on its last pass.
  ## The last `EventProtocolHealthChange` for `protocol` carried the same
  ## status. Before the first pass the status is `NOT_MOUNTED`.
  if self.healthMonitor.isNil():
    return ProtocolHealth.init(protocol)
  return self.healthMonitor.reportedProtocolHealth(protocol)
