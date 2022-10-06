{.push raises: [Defect].}

import
  stew/results,
  chronicles,
  ./storage/sqlite,
  ./storage/migration,
  ./config

logScope:
  topics = "wakunode.setup.migrations"


proc runMigrations*(sqliteDatabase: SqliteDatabase, conf: WakuNodeConf) =
  # Run migration scripts on persistent storage
  var migrationPath: string
  if conf.persistPeers and conf.persistMessages:
    migrationPath = ALL_STORE_MIGRATION_PATH
  elif conf.persistPeers:
    migrationPath = PEER_STORE_MIGRATION_PATH
  elif conf.persistMessages:
    migrationPath = MESSAGE_STORE_MIGRATION_PATH

  let migrationResult = sqliteDatabase.migrate(migrationPath)
  if migrationResult.isErr():
    warn "migration failed", error=migrationResult.error
  else:
    info "migration is done"
