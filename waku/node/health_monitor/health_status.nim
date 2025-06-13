import results

type HealthStatus* {.pure.} = enum
  INITIALIZING
  SYNCHRONIZING
  READY
  NOT_READY
  NOT_MOUNTED
  SHUTTING_DOWN

proc init*(t: typedesc[HealthStatus], strRep: string): Result[HealthStatus, string] =
  case strRep
  of "Initializing":
    return ok(HealthStatus.INITIALIZING)
  of "Synchronizing":
    return ok(HealthStatus.SYNCHRONIZING)
  of "Ready":
    return ok(HealthStatus.READY)
  of "Not Ready":
    return ok(HealthStatus.NOT_READY)
  of "Not Mounted":
    return ok(HealthStatus.NOT_MOUNTED)
  of "Shutting Down":
    return ok(HealthStatus.SHUTTING_DOWN)
  else:
    return err("Invalid HealthStatus string representation")
