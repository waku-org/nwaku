{.push raises: [].}

import std/[tables, strutils, os], stew/results, chronicles, chronos
import
  ../../../common/databases/common,
  ../../../../migrations/message_store_postgres/pg_migration_manager,
  ../postgres_driver

logScope:
  topics = "waku archive migration"

const SchemaVersion* = 4 # increase this when there is an update in the database schema

proc breakIntoStatements*(script: string): seq[string] =
  ## Given a full migration script, that can potentially contain a list
  ## of SQL statements, this proc splits it into the contained isolated statements
  ## that should be executed one after the other.
  var statements = newSeq[string]()

  let lines = script.split('\n')

  var simpleStmt: string
  var plSqlStatement: string
  var insidePlSqlScript = false
  for line in lines:
    if line.strip().len == 0:
      continue

    if insidePlSqlScript:
      if line.contains("END $$"):
        ## End of the Pl/SQL script
        plSqlStatement &= line
        statements.add(plSqlStatement)
        plSqlStatement = ""
        insidePlSqlScript = false
        continue
      else:
        plSqlStatement &= line & "\n"

    if line.contains("DO $$"):
      ## Beginning of the Pl/SQL script
      insidePlSqlScript = true
      plSqlStatement &= line & "\n"

    if not insidePlSqlScript:
      if line.contains(';'):
        ## End of simple statement
        simpleStmt &= line
        statements.add(simpleStmt)
        simpleStmt = ""
      else:
        simpleStmt &= line & "\n"

  return statements

proc migrate*(
    driver: PostgresDriver, targetVersion = SchemaVersion
): Future[DatabaseResult[void]] {.async.} =
  debug "starting message store's postgres database migration"

  let currentVersion = (await driver.getCurrentVersion()).valueOr:
    return err("migrate error could not retrieve current version: " & $error)

  if currentVersion == targetVersion:
    debug "database schema is up to date",
      currentVersion = currentVersion, targetVersion = targetVersion
    return ok()

  info "database schema is outdated",
    currentVersion = currentVersion, targetVersion = targetVersion

  # Load migration scripts
  let scripts = pg_migration_manager.getMigrationScripts(currentVersion, targetVersion)

  # Run the migration scripts
  for script in scripts:
    for statement in script.breakIntoStatements():
      debug "executing migration statement", statement = statement

      (await driver.performWriteQuery(statement)).isOkOr:
        error "failed to execute migration statement",
          statement = statement, error = error
        return err("failed to execute migration statement")

      debug "migration statement executed succesfully", statement = statement

  debug "finished message store's postgres database migration"

  return ok()
