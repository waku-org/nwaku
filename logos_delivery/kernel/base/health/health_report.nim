{.push raises: [].}

import
  logos_delivery/kernel/[
    base/health/health_status,
    base/health/connection_status,
    base/health/protocol_health,
  ]
type HealthReport* = object
  ## Rest API type returned for /health endpoint
  ##
  nodeHealth*: HealthStatus # legacy "READY" health indicator
  connectionStatus*: ConnectionStatus # new "Connected" health indicator
  protocolsHealth*: seq[ProtocolHealth]
