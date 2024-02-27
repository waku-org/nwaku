{.push raises: [].}

import
  std/[tables, strutils, os],
  stew/results,
  chronicles,
  chronos
import
  ../../../common/databases/common,
  ../../../../migrations/migration_utils,
  ../../../../migrations/message_store_postgres/pg_migration_manager,
  ../postgres_driver

logScope:
  topics = "waku archive migration"

const SchemaVersion* = 1 # increase this when there is an update in the database schema

proc migrate*(driver: PostgresDriver,
              targetVersion = SchemaVersion):
              Future[DatabaseResult[void]] {.async.} =

  debug "starting message store's postgres database migration"

  let currentVersion = (await driver.getCurrentVersion()).valueOr:
    return err("migrate error could not retrieve current version: " & $error)

  if currentVersion == targetVersion:
    debug "database schema is up to date",
          currentVersion=currentVersion, targetVersion=targetVersion
    return ok()

  info "database schema is outdated", currentVersion=currentVersion, targetVersion=targetVersion

  # Load migration scripts
  let scripts = pg_migration_manager.getMigrationScripts(currentVersion, targetVersion)

  # Run the migration scripts
  for script in scripts:

    for statement in script.breakIntoStatements():
      debug "executing migration statement", statement=statement

      (await driver.performWriteQuery(statement)).isOkOr:
        error "failed to execute migration statement", statement=statement, error=error
        return err("failed to execute migration statement")

      debug "migration statement executed succesfully", statement=statement

  debug "finished message store's postgres database migration"

  return ok()

