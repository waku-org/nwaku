import chronos, results, std/strutils
type ConnectionStatus* {.pure.} = enum
  Disconnected
  PartiallyConnected
  Connected

const HealthyThreshold* = 2
  ## Minimum peers required per service protocol for a "Connected" status (excluding Relay).

proc init*(
    t: typedesc[ConnectionStatus], strRep: string
): Result[ConnectionStatus, string] =
  try:
    let status = parseEnum[ConnectionStatus](strRep)
    return ok(status)
  except ValueError:
    return err("Invalid ConnectionStatus string representation: " & strRep)

type ConnectionStatusChangeHandler* =
  proc(status: ConnectionStatus): Future[void] {.gcsafe, raises: [Defect].}
