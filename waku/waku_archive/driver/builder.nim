when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import stew/results, chronicles, chronos
import
  ../driver,
  ../../common/databases/dburl,
  ../../common/databases/db_sqlite,
  ../../common/error_handling,
  ./sqlite_driver,
  ./sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ./queue_driver

export sqlite_driver, queue_driver

when defined(postgres):
  import ## These imports add dependency with an external libpq library
    ./postgres_driver/migrations as archive_postgres_driver_migrations,
    ./postgres_driver
  export postgres_driver

proc new*(
    T: type ArchiveDriver,
    url: string,
    vacuum: bool,
    migrate: bool,
    maxNumConn: int,
    onFatalErrorAction: OnFatalErrorHandler,
    legacy: bool = false,
): Future[Result[T, string]] {.async.} =
  ## url - string that defines the database
  ## vacuum - if true, a cleanup operation will be applied to the database
  ## migrate - if true, the database schema will be updated
  ## maxNumConn - defines the maximum number of connections to handle simultaneously (Postgres)
  ## onFatalErrorAction - called if, e.g., the connection with db got lost

  let dbUrlValidationRes = dburl.validateDbUrl(url)
  if dbUrlValidationRes.isErr():
    return err("DbUrl failure in ArchiveDriver.new: " & dbUrlValidationRes.error)

  let engineRes = dburl.getDbEngine(url)
  if engineRes.isErr():
    return err("error getting db engine in setupWakuArchiveDriver: " & engineRes.error)

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
    let sqliteStatsRes = db.gatherSqlitePageStats()
    if sqliteStatsRes.isErr():
      return err("error while gathering sqlite stats: " & $sqliteStatsRes.error)

    let (pageSize, pageCount, freelistCount) = sqliteStatsRes.get()
    debug "sqlite database page stats",
      pageSize = pageSize, pages = pageCount, freePages = freelistCount

    if vacuum and (pageCount > 0 and freelistCount > 0):
      let vacuumRes = db.performSqliteVacuum()
      if vacuumRes.isErr():
        return err("error in vacuum sqlite: " & $vacuumRes.error)

    # Database migration
    if migrate:
      let migrateRes = archive_driver_sqlite_migrations.migrate(db)
      if migrateRes.isErr():
        return err("error in migrate sqlite: " & $migrateRes.error)

    debug "setting up sqlite waku archive driver"

    if legacy:
      let res = LegacySqliteDriver.new(db)

      if res.isErr():
        return err("failed to init sqlite archive driver: " & res.error)

      return ok(res.get())
    else:
      let res = SqliteDriver.new(db)

      if res.isErr():
        return err("failed to init sqlite archive driver: " & res.error)

      return ok(res.get())
  of "postgres":
    when defined(postgres):
      if legacy:
        let res = LegacyPostgresDriver.new(
          dbUrl = url,
          maxConnections = maxNumConn,
          onFatalErrorAction = onFatalErrorAction,
        )
        if res.isErr():
          return err("failed to init postgres archive driver: " & res.error)

        let driver = res.get()

        # Database migration
        if migrate:
          let migrateRes = await archive_postgres_driver_migrations.migrate(driver)
          if migrateRes.isErr():
            return err("ArchiveDriver build failed in migration: " & $migrateRes.error)

        ## This should be started once we make sure the 'messages' table exists
        ## Hence, this should be run after the migration is completed.
        asyncSpawn driver.startPartitionFactory(onFatalErrorAction)

        info "waiting for a partition to be created"
        for i in 0 ..< 100:
          if driver.containsAnyPartition():
            break
          await sleepAsync(chronos.milliseconds(100))

        if not driver.containsAnyPartition():
          onFatalErrorAction("a partition could not be created")

        return ok(driver)
      else:
        let res = PostgresDriver.new(
          dbUrl = url,
          maxConnections = maxNumConn,
          onFatalErrorAction = onFatalErrorAction,
        )
        if res.isErr():
          return err("failed to init postgres archive driver: " & res.error)

        let driver = res.get()

        # Database migration
        if migrate:
          let migrateRes = await archive_postgres_driver_migrations.migrate(driver)
          if migrateRes.isErr():
            return err("ArchiveDriver build failed in migration: " & $migrateRes.error)

        ## This should be started once we make sure the 'messages' table exists
        ## Hence, this should be run after the migration is completed.
        asyncSpawn driver.startPartitionFactory(onFatalErrorAction)

        info "waiting for a partition to be created"
        for i in 0 ..< 100:
          if driver.containsAnyPartition():
            break
          await sleepAsync(chronos.milliseconds(100))

        if not driver.containsAnyPartition():
          onFatalErrorAction("a partition could not be created")

        return ok(driver)
    else:
      return err(
        "Postgres has been configured but not been compiled. Check compiler definitions."
      )
  else:
    debug "setting up in-memory waku archive driver"
    # Defaults to a capacity of 25.000 messages

    if legacy:
      let driver = LegacyQueueDriver.new()
      return ok(driver)
    else:
      let driver = QueueDriver.new()
      return ok(driver)
