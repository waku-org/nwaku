{.push raises: [].}

import
  logos_delivery/kernel/[
    common/health/health_status,
    common/health/connection_status,
    common/health/protocol_health,
  ]
type HealthReport* = object
  ## Rest API type returned for /health endpoint
  ##
  nodeHealth*: HealthStatus # legacy "READY" health indicator
  connectionStatus*: ConnectionStatus # new "Connected" health indicator
  protocolsHealth*: seq[ProtocolHealth]
