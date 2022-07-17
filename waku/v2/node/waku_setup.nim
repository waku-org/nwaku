{.push raises: [Defect].}

## Collection of utilities commonly used
## during the setup phase of a Waku v2 node

import
  std/tables,
  chronos,
  chronicles,
  metrics,
  metrics/chronos_httpserver,
  stew/results,
  stew/shims/net,
  ./storage/sqlite,
  ./storage/migration/migration_types,
  ./config,
  ./wakunode2

logScope:
  topics = "wakunode.setup"

type
  SetupResult*[T] = Result[T, string]

##########################
# Setup helper functions #
##########################

proc runMigrations*(sqliteDatabase: SqliteDatabase, conf: WakuNodeConf) =
  # Run migration scripts on persistent storage

  var migrationPath: string
  if conf.persistPeers and conf.persistMessages:
    migrationPath = migration_types.ALL_STORE_MIGRATION_PATH
  elif conf.persistPeers:
    migrationPath = migration_types.PEER_STORE_MIGRATION_PATH
  elif conf.persistMessages:
    migrationPath = migration_types.MESSAGE_STORE_MIGRATION_PATH

  # run migration 
  info "running migration ...", migrationPath=migrationPath
  let migrationResult = sqliteDatabase.migrate(migrationPath)
  if migrationResult.isErr:
    warn "migration failed", error=migrationResult.error
  else:
    info "migration is done"
