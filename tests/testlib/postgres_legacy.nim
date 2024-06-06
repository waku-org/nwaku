import chronicles, chronos
import
  ../../../waku/waku_archive_legacy,
  ../../../waku/waku_archive_legacy/driver as driver_module,
  ../../../waku/waku_archive_legacy/driver/builder,
  ../../../waku/waku_archive_legacy/driver/postgres_driver

const storeMessageDbUrl = "postgres://postgres:test123@localhost:5432/postgres"

proc newTestPostgresDriver*(): Future[Result[ArchiveDriver, string]] {.
    async, deprecated
.} =
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
