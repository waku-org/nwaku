{.push raises: [Defect].}

import 
  std/[os, algorithm, tables, strutils], 
  chronicles, 
  stew/results,
  migration_types

export migration_types

logScope:
  topics = "storage.migration"


proc getScripts*(migrationPath: string): MigrationScriptsResult[MigrationScripts] =
  ## the code in this procedure is an adaptation of https://github.com/status-im/nim-status/blob/21aebe41be03cb6450ea261793b800ed7d3e6cda/nim_status/migrations/sql_generate.nim#L4
  var migrationScripts = MigrationScripts(migrationUp:initOrderedTable[string, string](), migrationDown:initOrderedTable[string, string]())
  try:
    for path in walkDirRec(migrationPath):
      let (_, name, ext) = splitFile(path)
      if ext != ".sql": continue

      let parts = name.split(".")
      if parts.len < 2:
        continue
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
  
    ok(migrationScripts)

  except OSError, IOError:
    debug "failed to load the migration scripts"
    return err("failed to load the migration scripts") 


proc filterScripts*(migrationScripts: MigrationScripts, s: int64, e: int64 ): Result[seq[string], string] = 
  ## returns migration scripts whose version fall between s and e (e is inclusive)
  var scripts: seq[string]
  try:
    for name, script in migrationScripts.migrationUp:
      let parts = name.split("_")
      #TODO this should be int64
      let ver = parseInt(parts[0])
      # filter scripts based on their version
      if s < ver and ver <= e:
        scripts.add(script)
    ok(scripts)
  except ValueError:
    return err("failed to filter scripts")

proc splitScript*(script: string): seq[string] =
  ## parses the script into its  individual sql commands and returns them
  var queries: seq[string] = @[]
  for q in script.split(';'):
    if  isEmptyOrWhitespace(q): continue
    let query = q.strip() & ";"
    queries.add(query)
  return queries
