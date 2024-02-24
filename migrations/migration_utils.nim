import
  std/[strutils,sequtils,os,algorithm],
  stew/results
import
  chronicles
import
  ../waku/common/databases/common

## Migration scripts

proc getMigrationScriptVersion(path: string): DatabaseResult[int64] =
  let name = extractFilename(path)
  let parts = name.split("_", 1)

  try:
    let version = parseInt(parts[0])
    return ok(version)
  except ValueError:
    return err("failed to parse file version: " & name)

proc breakIntoStatements*(script: string): seq[string] =
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
      simpleStmt &= line & "\n"

      if line.contains(';'):
        ## End of simple statement
        statements.add(simpleStmt)
        simpleStmt = ""

  return statements

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

proc filterMigrationScripts(paths: seq[string],
                            lowVersion, highVersion: int64,
                            direction: string = "up"):
                            seq[string] =
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

proc loadMigrationScripts*(migrationsScriptsDir: string,
                           userVersion: int64,
                           targetVersion: int64): DatabaseResult[seq[string]] =

  var migrationScriptsPaths = ? listSqlScripts(migrationsScriptsDir)
  migrationScriptsPaths = filterMigrationScripts(migrationScriptsPaths,
                                                 lowVersion=userVersion,
                                                 highVersion=targetVersion,
                                                 direction="up")
  migrationScriptsPaths = sortMigrationScripts(migrationScriptsPaths)

  if migrationScriptsPaths.len <= 0:
    return err("no scripts to be run")

  var loadedScripts = newSeq[string]()

  for script in migrationScriptsPaths:
    try:
      loadedScripts.add(readFile(script))
    except OSError, IOError:
      return err("failed to load script '" & script & "': " & getCurrentExceptionMsg())

  ok(loadedScripts)
