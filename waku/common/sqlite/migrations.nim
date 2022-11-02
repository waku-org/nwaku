{.push raises: [].}

import 
  std/[strutils, sequtils, os, algorithm],
  stew/results,
  chronicles
import
  ../sqlite
  

logScope:
  topics = "sqlite"


## Migration scripts

proc getMigrationScriptVersion(path: string): DatabaseResult[int64] =
  let name = extractFilename(path)
  let parts = name.split("_", 1)

  try:
    let version = parseInt(parts[0])
    return ok(version)
  except ValueError:
    return err("failed to parse file version: " & name)

proc isSqlScript(path: string): bool =
  path.toLower().endsWith(".sql")


proc listSqlScripts(path: string): DatabaseResult[seq[string]] =
  var scripts = newSeq[string]()

  try: 
    for scriptPath in walkDirRec(path):
      if isSqlScript(scriptPath):
        scripts.add(scriptPath)
      else:
        debug "invalid migration script", file=scriptPath
  except OSError:
    return err("failed to list migration scripts: " & getCurrentExceptionMsg())

  ok(scripts)


proc filterMigrationScripts(paths: seq[string], lowVersion, highVersion: int64, direction: string = "up"): seq[string] =
  ## Returns migration scripts whose version fall between lowVersion and highVersion (inclusive)
  let filterPredicate = proc(script: string): bool =
      if not isSqlScript(script):
        return false

      if direction != "" and not script.toLower().endsWith("." & direction & ".sql"):
        return false

      let scriptVersionRes = getMigrationScriptVersion(script)
      if scriptVersionRes.isErr():
        return false
      
      let scriptVersion = scriptVersionRes.value
      return lowVersion < scriptVersion and scriptVersion <= highVersion

  paths.filter(filterPredicate)


proc sortMigrationScripts(paths: seq[string]): seq[string] =
  ## Sort migration scripts paths alphabetically
  paths.sorted(system.cmp[string])


proc loadMigrationScripts(paths: seq[string]): DatabaseResult[seq[string]] =
  var loadedScripts = newSeq[string]()

  for script in paths:
    try:
      loadedScripts.add(readFile(script))
    except OSError, IOError:
      return err("failed to load script '" & script & "': " & getCurrentExceptionMsg())

  ok(loadedScripts)


proc breakIntoStatements(script: string): seq[string] =
  var statements = newSeq[string]()

  for chunk in script.split(';'):
    if chunk.strip().isEmptyOrWhitespace(): 
      continue

    let statement = chunk.strip() & ";"
    statements.add(statement)

  statements


proc migrate*(db: SqliteDatabase, targetVersion: int64, migrationsScriptsDir: string): DatabaseResult[void] =
  ## Compares the `user_version` of the sqlite database with the provided `targetVersion`, then
  ## it runs migration scripts if the `user_version` is outdated. The `migrationScriptsDir` path
  ## points to the directory holding the migrations scripts once the db is updated, it sets the
  ## `user_version` to the `tragetVersion`.
  ##
  ## NOTE: Down migration it is not currently supported
  let userVersion = ?db.getUserVersion()

  if userVersion == targetVersion:
    debug "database schema is up to date", userVersion=userVersion, targetVersion=targetVersion
    return ok()
  
  info "database schema is outdated", userVersion=userVersion, targetVersion=targetVersion

  # Load migration scripts
  var migrationScriptsPaths = ?listSqlScripts(migrationsScriptsDir)
  migrationScriptsPaths = filterMigrationScripts(migrationScriptsPaths, lowVersion=userVersion, highVersion=targetVersion, direction="up")
  migrationScriptsPaths = sortMigrationScripts(migrationScriptsPaths)
  
  if migrationScriptsPaths.len <= 0:
    debug "no scripts to be run"
    return ok()

  let scripts = ?loadMigrationScripts(migrationScriptsPaths)

  # Run the migration scripts
  for script in scripts:

    for statement in script.breakIntoStatements():
      debug "executing migration statement", statement=statement

      let execRes = db.query(statement, NoopRowHandler)
      if execRes.isErr():
        error "failed to execute migration statement", statement=statement, error=execRes.error
        return err("failed to execute migration statement")

      debug "migration statement executed succesfully", statement=statement
    
  # Update user_version
  ?db.setUserVersion(targetVersion)

  debug "database user_version updated", userVersion=targetVersion
  ok()
