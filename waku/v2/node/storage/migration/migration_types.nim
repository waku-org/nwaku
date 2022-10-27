{.push raises: [Defect].}

import tables, stew/results, strutils, os

template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const MessageStoreMigrationPath* = sourceDir / "migrations_scripts/message"
const PeerStoreMigrationPath* = sourceDir / "migrations_scripts/peer"
const AllStoreMigrationPath* = sourceDir / "migrations_scripts"

type MigrationScriptsResult*[T] = Result[T, string]
type
  MigrationScripts* = ref object of RootObj
    migrationUp*:OrderedTable[string, string]
    migrationDown*:OrderedTable[string, string]