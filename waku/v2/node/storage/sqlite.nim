{.push raises: [Defect].}

import 
  os,
  sqlite3_abi,
  chronicles,
  stew/results,
  migration/migration_utils
# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
#
# Most of it is a direct copy, the only unique functions being `get` and `put`.

logScope:
  topics = "sqlite"

type
  DatabaseResult*[T] = Result[T, string]

  Sqlite = ptr sqlite3

  NoParams* = tuple
  RawStmtPtr* = ptr sqlite3_stmt
  SqliteStmt*[Params; Result] = distinct RawStmtPtr

  AutoDisposed[T: ptr|ref] = object
    val: T

  SqliteDatabase* = ref object of RootObj
    env*: Sqlite

template dispose(db: Sqlite) =
  discard sqlite3_close(db)

template dispose(rawStmt: RawStmtPtr) =
  discard sqlite3_finalize(rawStmt)

template dispose*(sqliteStmt: SqliteStmt) =
  discard sqlite3_finalize(RawStmtPtr sqliteStmt)

proc release[T](x: var AutoDisposed[T]): T =
  result = x.val
  x.val = nil

proc disposeIfUnreleased[T](x: var AutoDisposed[T]) =
  mixin dispose
  if x.val != nil:
    dispose(x.release)

template checkErr*(op, cleanup: untyped) =
  if (let v = (op); v != SQLITE_OK):
    cleanup
    return err($sqlite3_errstr(v))

template checkErr*(op) =
  checkErr(op): discard

proc init*(
    T: type SqliteDatabase,
    basePath: string,
    name: string = "store",
    readOnly = false,
    inMemory = false): DatabaseResult[T] =
  var env: AutoDisposed[ptr sqlite3]
  defer: disposeIfUnreleased(env)

  let
    name =
      if inMemory: ":memory:"
      else: basepath / name & ".sqlite3"
    flags =
      if readOnly: SQLITE_OPEN_READONLY
      else: SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE

  if not inMemory:
    try:
      createDir(basePath)
    except OSError, IOError:
      return err("`sqlite: cannot create database directory")

  checkErr sqlite3_open_v2(name, addr env.val, flags.cint, nil)

  template prepare(q: string, cleanup: untyped): ptr sqlite3_stmt =
    var s: ptr sqlite3_stmt
    checkErr sqlite3_prepare_v2(env.val, q, q.len.cint, addr s, nil):
      cleanup
    s

  template checkExec(s: ptr sqlite3_stmt) =
    if (let x = sqlite3_step(s); x != SQLITE_DONE):
      discard sqlite3_finalize(s)
      return err($sqlite3_errstr(x))

    if (let x = sqlite3_finalize(s); x != SQLITE_OK):
      return err($sqlite3_errstr(x))

  template checkExec(q: string) =
    let s = prepare(q): discard
    checkExec(s)

  template checkWalPragmaResult(journalModePragma: ptr sqlite3_stmt) =
    if (let x = sqlite3_step(journalModePragma); x != SQLITE_ROW):
      discard sqlite3_finalize(journalModePragma)
      return err($sqlite3_errstr(x))

    if (let x = sqlite3_column_type(journalModePragma, 0); x != SQLITE3_TEXT):
      discard sqlite3_finalize(journalModePragma)
      return err($sqlite3_errstr(x))

    if (let x = sqlite3_column_text(journalModePragma, 0);
        x != "memory" and x != "wal"):
      discard sqlite3_finalize(journalModePragma)
      return err("Invalid pragma result: " & $x)


  let journalModePragma = prepare("PRAGMA journal_mode = WAL;"): discard
  checkWalPragmaResult(journalModePragma)
  checkExec(journalModePragma)

  ok(SqliteDatabase(
    env: env.release
  ))

template prepare*(env: Sqlite, q: string, cleanup: untyped): ptr sqlite3_stmt =
  var s: ptr sqlite3_stmt
  checkErr sqlite3_prepare_v2(env, q, q.len.cint, addr s, nil):
    cleanup
  s

proc bindParam*(s: RawStmtPtr, n: int, val: auto): cint =
  when val is openarray[byte]|seq[byte]:
    if val.len > 0:
      sqlite3_bind_blob(s, n.cint, unsafeAddr val[0], val.len.cint, nil)
    else:
      sqlite3_bind_blob(s, n.cint, nil, 0.cint, nil)
  elif val is int32:
    sqlite3_bind_int(s, n.cint, val)
  elif val is uint32:
    sqlite3_bind_int64(s, n.cint, val)
  elif val is int64:
    sqlite3_bind_int64(s, n.cint, val)
  elif val is float64:
    sqlite3_bind_double(s, n.cint, val)
  # Note: bind_text not yet supported in sqlite3_abi wrapper
  # elif val is string:
  #   sqlite3_bind_text(s, n.cint, val.cstring, -1, nil)  # `-1` implies string length is the number of bytes up to the first null-terminator
  else:
    {.fatal: "Please add support for the '" & $typeof(val) & "' type".}

template bindParams(s: RawStmtPtr, params: auto) =
  when params is tuple:
    var i = 1
    for param in fields(params):
      checkErr bindParam(s, i, param)
      inc i
  else:
    checkErr bindParam(s, 1, params)

proc exec*[P](s: SqliteStmt[P, void], params: P): DatabaseResult[void] =
  let s = RawStmtPtr s
  bindParams(s, params)

  let res =
    if (let v = sqlite3_step(s); v != SQLITE_DONE):
      err($sqlite3_errstr(v))
    else:
      ok()

  # release implict transaction
  discard sqlite3_reset(s) # same return information as step
  discard sqlite3_clear_bindings(s) # no errors possible

  res

template readResult(s: RawStmtPtr, column: cint, T: type): auto =
  when T is Option:
    if sqlite3_column_type(s, column) == SQLITE_NULL:
      none(typeof(default(T).get()))
    else:
      some(readSimpleResult(s, column, typeof(default(T).get())))
  else:
    readSimpleResult(s, column, T)

template readResult(s: RawStmtPtr, T: type): auto =
  when T is tuple:
    var res: T
    var i = cint 0
    for field in fields(res):
      field = readResult(s, i, typeof(field))
      inc i
    res
  else:
    readResult(s, 0.cint, T)

type 
  DataProc* = proc(s: ptr sqlite3_stmt) {.closure.} # the nim-eth definition is different; one more indirection

proc exec*[Params, Res](s: SqliteStmt[Params, Res],
                        params: Params,
                        onData: DataProc): DatabaseResult[bool] =
  let s = RawStmtPtr s
  bindParams(s, params)

  try:
    var gotResults = false
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        onData(s)
        gotResults = true
      of SQLITE_DONE:
        break
      else:
        return err($sqlite3_errstr(v))
    return ok gotResults
  finally:
    # release implicit transaction
    discard sqlite3_reset(s) # same return information as step
    discard sqlite3_clear_bindings(s) # no errors possible


proc query*(db: SqliteDatabase, query: string, onData: DataProc): DatabaseResult[bool] =
  var s = prepare(db.env, query): discard

  try:
    var gotResults = false
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        onData(s)
        gotResults = true
      of SQLITE_DONE:
        break
      else:
        return err($sqlite3_errstr(v))
    return ok gotResults
  finally:
    # release implicit transaction
    discard sqlite3_reset(s) # same return information as step
    discard sqlite3_clear_bindings(s) # no errors possible
    discard sqlite3_finalize(s) # NB: dispose of the prepared query statement and free associated memory

proc prepareStmt*(
  db: SqliteDatabase,
  stmt: string,
  Params: type,
  Res: type
): DatabaseResult[SqliteStmt[Params, Res]] =
  var s: RawStmtPtr
  checkErr sqlite3_prepare_v2(db.env, stmt, stmt.len.cint, addr s, nil)
  ok SqliteStmt[Params, Res](s)

proc close*(db: SqliteDatabase) =
  discard sqlite3_close(db.env)

  db[] = SqliteDatabase()[]

proc getUserVersion*(database: SqliteDatabase): DatabaseResult[int64] = 
  var version: int64
  proc handler(s: ptr sqlite3_stmt) = 
    version = sqlite3_column_int64(s, 0)
  let res = database.query("PRAGMA user_version;", handler)
  if res.isErr:
      return err("failed to get user_version")
  ok(version)


proc setUserVersion*(database: SqliteDatabase, version: int64): DatabaseResult[void] = 
  ## sets  the value of the user-version integer at offset 60 in the database header. 
  ## some context borrowed from https://www.sqlite.org/pragma.html#pragma_user_version
  ## The user-version is an integer that is available to applications to use however they want. 
  ## SQLite makes no use of the user-version itself
  proc handler(s: ptr sqlite3_stmt) = discard

  let query = "PRAGMA user_version=" & $version & ";"
  let res = database.query(query, handler)
  if res.isErr():
      return err("failed to set user_version")

  ok()


proc migrate*(db: SqliteDatabase, path: string, targetVersion: int64 = migration_utils.USER_VERSION): DatabaseResult[bool] = 
  ## compares the user_version of the db with the targetVersion 
  ## runs migration scripts if the user_version is outdated (does not support down migration)
  ## path points to the directory holding the migrations scripts
  ## once the db is updated, it sets the user_version to the tragetVersion
  
  # read database version
  let userVersion = db.getUserVersion()
  debug "current db user_version", userVersion=userVersion
  if userVersion.value == targetVersion:
    # already up to date
    info "database is up to date"
    ok(true)
  
  else:
    info "database user_version outdated. migrating.", userVersion=userVersion, targetVersion=targetVersion
    # TODO check for the down migrations i.e., userVersion.value > tragetVersion
    # fetch migration scripts
    let migrationScriptsRes = getScripts(path)
    if migrationScriptsRes.isErr:
      return err("failed to load migration scripts")
    let migrationScripts = migrationScriptsRes.value
  
    # filter scripts based on their versions
    let scriptsRes = migrationScripts.filterScripts(userVersion.value, targetVersion)
    if scriptsRes.isErr:
      return err("failed to filter migration scripts")
    
    let scripts = scriptsRes.value
    if (scripts.len == 0):
      return err("no suitable migration scripts")
    
    debug "scripts to be run", scripts=scripts
    
    
    proc handler(s: ptr sqlite3_stmt) = 
      discard
    
    # run the scripts
    for script in scripts:
      debug "script", script=script
      # a script may contain multiple queries
      let queries = script.splitScript()
      # TODO queries of the same script should be executed in an atomic manner
      for query in queries:
        let res = db.query(query, handler)
        if res.isErr:
          debug "failed to run the query", query=query
          return err("failed to run the script")
        else:
          debug "query is executed", query=query

    
    # bump the user version
    let res = db.setUserVersion(targetVersion)
    if res.isErr:
      return err("failed to set the new user_version")

    debug "user_version is set to", targetVersion=targetVersion
    ok(true)
