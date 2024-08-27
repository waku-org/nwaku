{.push raises: [].}

import std/[tables, strutils, os], results, chronicles
import ../../../common/databases/db_sqlite, ../../../common/databases/common

logScope:
  topics = "waku node delivery_monitor"

const TargetSchemaVersion* = 1
  # increase this when there is an update in the database schema

template projectRoot(): string =
  currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / ".." / ".."

const PeerStoreMigrationPath: string = projectRoot / "migrations" / "sent_msgs"

proc migrate*(db: SqliteDatabase): DatabaseResult[void] =
  debug "starting peer store's sqlite database migration for sent messages"

  let migrationRes =
    migrate(db, TargetSchemaVersion, migrationsScriptsDir = PeerStoreMigrationPath)
  if migrationRes.isErr():
    return err("failed to execute migration scripts: " & migrationRes.error)

  debug "finished peer store's sqlite database migration for sent messages"
  ok()
