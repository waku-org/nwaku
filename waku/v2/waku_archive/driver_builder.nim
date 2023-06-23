
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  chronicles
import
  ./driver_base,
  ../../common/databases/dburl,
  ../../common/databases/db_sqlite,
  ./driver/sqlite_driver,
  ./driver/sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ./driver/queue_driver

export
  sqlite_driver,
  queue_driver

proc new*(T: type ArchiveDriver,
          url: string,
          vacuum: bool,
          migrate: bool):
          Result[T, string] =

  let dbUrlValidationRes = dburl.validateDbUrl(url)
  if dbUrlValidationRes.isErr():
    return err("DbUrl failure in ArchiveDriver.new: " &
               dbUrlValidationRes.error)

  let engineRes = dburl.getDbEngine(url)
  if engineRes.isErr():
    return err("error getting db engine in setupWakuArchiveDriver: " &
               engineRes.error)

  let engine = engineRes.get()

  case engine
  of "sqlite":
    let pathRes = dburl.getDbPath(url)
    if pathRes.isErr():
      return err("error get path in setupWakuArchiveDriver: " & pathRes.error)

    let dbRes = SqliteDatabase.new(pathRes.get())
    if dbRes.isErr():
      return err("error in setupWakuArchiveDriver: " & dbRes.error)

    let db = dbRes.get()

    # SQLite vacuum
    let (pageSize, pageCount, freelistCount) = ? db.gatherSqlitePageStats()
    debug "sqlite database page stats", pageSize = pageSize,
                                        pages = pageCount,
                                        freePages = freelistCount

    if vacuum and (pageCount > 0 and freelistCount > 0):
      ? db.performSqliteVacuum()

    # Database migration
    if migrate:
      ? archive_driver_sqlite_migrations.migrate(db)

    debug "setting up sqlite waku archive driver"
    let res = SqliteDriver.new(db)
    if res.isErr():
      return err("failed to init sqlite archive driver: " & res.error)

    return ok(res.get())

  else:
    debug "setting up in-memory waku archive driver"
    let driver = QueueDriver.new()  # Defaults to a capacity of 25.000 messages
    return ok(driver)
