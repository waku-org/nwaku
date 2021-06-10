import 
  os, algorithm, tables, strutils, chronicles,
  migration_types

proc getMigrationScripts*(migrationPath: string): MigrationScripts =
  ## this code is borrowed from https://github.com/status-im/nim-status/blob/21aebe41be03cb6450ea261793b800ed7d3e6cda/nim_status/migrations/sql_generate.nim#L4
  var migrationScripts = MigrationScripts(migrationUp:initOrderedTable[string, string](), migrationDown:initOrderedTable[string, string]())

  for kind, path in walkDir(migrationPath):
    let (_, name, ext) = splitFile(path)
    if ext != ".sql": continue

    let parts = name.split(".")
    let script = parts[0]
    let direction = parts[1]

    debug "name", script=script
    case direction:
    of "up":
      migrationScripts.migrationUp[script] = readFile(path)
      debug "up script", readScript=migrationScripts.migrationUp[script]
    of "down":
      migrationScripts.migrationDown[script] = readFile(path)
      debug "down script", readScript=migrationScripts.migrationDown[script]
    else:
      debug "Invalid script: ", name

  migrationScripts.migrationUp.sort(system.cmp)
  migrationScripts.migrationDown.sort(system.cmp)
 

  return migrationScripts

proc filterMigrationScripts*(migrationScripts: MigrationScripts, version: int64): seq[string] = 
  ## filters migration scripts whose version is higher than the given version 
  for name, query in migrationScripts.migrationUp:
    let parts = name.split("_")
    #TODO this should be int64
    let ver = parseInt(parts[0])
    # fetch scripts for higher versions
    if version < ver:
      result.add(query)
