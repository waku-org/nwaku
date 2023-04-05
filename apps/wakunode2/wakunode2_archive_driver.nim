import
  std/strutils,
  chronicles,
  stew/results,
  ../../waku/v2/protocol/waku_archive,
  ../../waku/v2/config,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver,
  ../../waku/v2/protocol/waku_archive/driver/postgres_driver,
  ../../waku/v2/protocol/waku_archive/driver/queue_driver,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ../../waku/common/sqlite

type SetupResult[T] = Result[T, string]

proc performSqliteVacuum(db: SqliteDatabase): SetupResult[void] =
  ## SQLite database vacuuming
  # TODO: Run vacuuming conditionally based on database page stats
  # if (pageCount > 0 and freelistCount > 0):

  debug "starting sqlite database vacuuming"

  let resVacuum = db.vacuum()
  if resVacuum.isErr():
    return err("failed to execute vacuum: " & resVacuum.error)

  debug "finished sqlite database vacuuming"



proc gatherSqlitePageStats(db: SqliteDatabase): SetupResult[(int64, int64, int64)] =
  let
    pageSize = ?db.getPageSize()
    pageCount = ?db.getPageCount()
    freelistCount = ?db.getFreelistCount()

  ok((pageSize, pageCount, freelistCount))


proc setupSqliteDriver(conf: WakuNodeConf, path: string): SetupResult[ArchiveDriver] =
  let res = SqliteDatabase.new(path)

  if res.isErr():
    return err("could not create sqlite database")

  let database = res.get()

  # TODO: Run this only if the database engine is SQLite
  let (pageSize, pageCount, freelistCount) = ?gatherSqlitePageStats(database)
  debug "sqlite database page stats", pageSize=pageSize, pages=pageCount, freePages=freelistCount

  if conf.storeMessageDbVacuum and (pageCount > 0 and freelistCount > 0):
    ?performSqliteVacuum(database)

# Database migration
  if conf.storeMessageDbMigration:
    ?archive_driver_sqlite_migrations.migrate(database)

  debug "setting up sqlite waku archive driver"
  let sqliteDriverRes = SqliteDriver.new(database)
  if sqliteDriverRes.isErr():
    return err("failed to init sqlite archive driver: " & res.error)

  ok(sqliteDriverRes.value)

proc setupPostgresDriver(conf: WakuNodeConf): SetupResult[ArchiveDriver] =
  let res = PostgresDriver.new(conf)
  if res.isErr():
    return err("could not create postgres driver")

  ok(res.value)

proc setupWakuArchiveDriver*(conf: WakuNodeConf): SetupResult[ArchiveDriver] =
  if conf.storeMessageDbUrl == "" or conf.storeMessageDbUrl == "none":
    let driver = QueueDriver.new()  # Defaults to a capacity of 25.000 messages
    return ok(driver)

  let dbUrlParts = conf.storeMessageDbUrl.split("://", 1)
  let
    engine = dbUrlParts[0]
    path = dbUrlParts[1]

  let connRes = case engine
    of "sqlite":
      setupSqliteDriver(conf, path)
    of "postgres":
      setupPostgresDriver(conf)
    else:
      return err("unknown database engine")

  if connRes.isErr():
    return err("failed to init connection" & connRes.error)
  ok(connRes.get())


