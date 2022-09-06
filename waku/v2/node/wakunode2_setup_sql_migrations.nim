{.push raises: [Defect].}

import
  stew/results,
  chronicles,
  ./storage/sqlite,
  ./storage/migration/migration_types,
  ./config

logScope:
  topics = "wakunode.setup.migrations"


proc runMigrations*(sqliteDatabase: SqliteDatabase, conf: WakuNodeConf) =
  # Run migration scripts on persistent storage
  var migrationPath: string
  if conf.persistPeers and conf.persistMessages:
    migrationPath = migration_types.ALL_STORE_MIGRATION_PATH
  elif conf.persistPeers:
    migrationPath = migration_types.PEER_STORE_MIGRATION_PATH
  elif conf.persistMessages:
    migrationPath = migration_types.MESSAGE_STORE_MIGRATION_PATH

  info "running migration ...", migrationPath=migrationPath
  let migrationResult = sqliteDatabase.migrate(migrationPath)
  if migrationResult.isErr():
    warn "migration failed", error=migrationResult.error()
  else:
    info "migration is done"
