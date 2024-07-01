import chronicles, chronos
import
  waku/waku_archive,
  waku/waku_archive/driver as driver_module,
  waku/waku_archive/driver/builder,
  waku/waku_archive/driver/postgres_driver

const storeMessageDbUrl = "postgres://postgres:test123@localhost:5432/postgres"

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
