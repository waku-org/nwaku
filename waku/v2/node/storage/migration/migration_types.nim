import tables, stew/results, strutils, os

template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const MESSAGE_STORE_MIGRATION_PATH* = sourceDir / "migrations_scripts/message"
const PEER_STORE_MIGRATION_PATH* = sourceDir / "migrations_scripts/peer"
const ALL_STORE_MIGRATION_PATH* = sourceDir / "migrations_scripts"

const USER_VERSION* = 2 # increase this when there is an update in the database schema

type MigrationScriptsResult*[T] = Result[T, string]
type
  MigrationScripts* = ref object of RootObj
    migrationUp*:OrderedTable[string, string]
    migrationDown*:OrderedTable[string, string]