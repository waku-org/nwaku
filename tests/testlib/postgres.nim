import chronicles, chronos
import
  logos_delivery/kernel/[
    archive/common,
    archive/archive,
    archive/driver,
    archive/retention_policy,
    archive/driver as driver_module,
    archive/driver/builder,
    archive/driver/postgres_driver/postgres_driver,
    archive/driver/postgres_driver/partitions_manager,
    archive/driver/postgres_driver/postgres_healthcheck,
  ]

const storeMessageDbUrl* = "postgres://postgres:test123@localhost:5432/postgres"

proc newTestPostgresDriver*(): Future[Result[ArchiveDriver, string]] {.async.} =
  proc onErr(errMsg: string) {.gcsafe, closure.} =
    error "error creating ArchiveDriver", error = errMsg
    quit(QuitFailure)

  let
    vacuum = false
    migrate = true
    maxNumConn = 50

  let driverRes =
    await ArchiveDriver.new(storeMessageDbUrl, vacuum, migrate, maxNumConn, onErr)
  if driverRes.isErr():
    onErr("could not create archive driver: " & driverRes.error)

  return ok(driverRes.get())
