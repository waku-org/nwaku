{.push raises: [].}

import
  std/[tables, strutils, os],
  stew/results,
  chronicles
import
  ../../../common/databases/db_sqlite,
  ../../../common/databases/common


logScope:
  topics = "waku archive migration"


const SchemaVersion* = 7 # increase this when there is an update in the database schema

template projectRoot: string = currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / ".." / ".."
const MessageStoreMigrationPath: string = projectRoot / "migrations" / "message_store"

proc getNumColumnsInPK*(db: SqliteDatabase): DatabaseResult[int64] =
  ## Temporary proc created to extract the number of columns the PK has in the Message table.
  ## This is to consider whether the table actually belongs to the SchemaVersion 7.
  ## During many nwaku versions (0.13.0 until 0.18.0), the SchemaVersion wasn't set or checked
  ## and therefore, in 0.19.0 we started to check it and the migration started to fail because
  ## the migration scripts tried to migrate a database that was already in SchemaVersion 7,
  ## and that made it to crash.
  ##
  ## TODO: remove this proc after 0.23.0

  var count: int64
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    count = sqlite3_column_int64(s, 0)

  let query = """SELECT count(l.name) FROM pragma_table_info("Message") as l WHERE l.pk != 0;"""
  let res = db.query(query, queryRowCallback)
  if res.isErr():
    return err("failed to count number of messages in the database")

  ok(count)

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

  let userVersion = ? db.getUserVersion()
  let numColumnsInPK = ? db.getNumColumnsInPK()

  if userVersion == 0'i64 and numColumnsInPK == 3:
    info "We found user_version 0 but the database schema reflects the user_version 7"
    ## Force the correct schema version
    ? db.setUserVersion( 7 )
    return ok()

  let migrationRes = migrate(db, targetVersion, migrationsScriptsDir=MessageStoreMigrationPath)
  if migrationRes.isErr():
    return err("failed to execute migration scripts: " & migrationRes.error)

  debug "finished message store's sqlite database migration"
  ok()
