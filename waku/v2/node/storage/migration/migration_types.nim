{.push raises: [].}

import 
  std/[tables, os, strutils],
  stew/results

template projectRoot: string = currentSourcePath.rsplit(DirSep, 1)[0] / ".." / ".." / ".." / ".." / ".."
const MessageStoreMigrationPath* = projectRoot / "migrations" / "message_store"
const PeerStoreMigrationPath* = projectRoot / "migrations" / "peer_store"

type MigrationScriptsResult*[T] = Result[T, string]
type
  MigrationScripts* = ref object of RootObj
    migrationUp*:OrderedTable[string, string]
    migrationDown*:OrderedTable[string, string]