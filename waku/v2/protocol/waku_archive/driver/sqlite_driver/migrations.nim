{.push raises: [].}

import
  std/[tables, strutils, os],
  stew/results,
  chronicles
import
  ../../../../../common/sqlite,
  ../../../../../common/sqlite/migrations


logScope:
  topics = "message_store.migration"


const SchemaVersion* = 7 # increase this when there is an update in the database schema

template projectRoot: string = currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / ".." / ".." / ".."
const MessageStoreMigrationPath: string = projectRoot / "migrations" / "message_store"


proc migrate*(db: SqliteDatabase, targetVersion = SchemaVersion): DatabaseResult[void] =
  ## Compares the `user_version` of the sqlite database with the provided `targetVersion`, then
  ## it runs migration scripts if the `user_version` is outdated. The `migrationScriptsDir` path
  ## points to the directory holding the migrations scripts once the db is updated, it sets the
  ## `user_version` to the `tragetVersion`.
  ##
  ## If not `targetVersion` is provided, it defaults to `SchemaVersion`.
  ##
  ## NOTE: Down migration it is not currently supported
  debug "starting message store's sqlite database migration"

  let migrationRes = migrations.migrate(db, targetVersion, migrationsScriptsDir=MessageStoreMigrationPath)
  if migrationRes.isErr():
    return err("failed to execute migration scripts: " & migrationRes.error)

  debug "finished message store's sqlite database migration"
  ok()
