import 
  os,
  sqlite3_abi,
  chronos, chronicles, metrics, stew/results,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  stew/results, metrics

{.push raises: [Defect].}

# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
#
# Most of it is a direct copy, the only unique functions being `get` and `put`.

type
  DatabaseResult*[T] = Result[T, string]

  Sqlite = ptr sqlite3

  NoParams* = tuple
  RawStmtPtr = ptr sqlite3_stmt
  SqliteStmt*[Params; Result] = distinct RawStmtPtr

  AutoDisposed[T: ptr|ref] = object
    val: T

  SqliteDatabase* = ref object of RootObj
    env*: Sqlite

template dispose(db: Sqlite) =
  discard sqlite3_close(db)

template dispose(db: RawStmtPtr) =
  discard sqlite3_finalize(db)

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

  # TODO: check current version and implement schema versioning
  checkExec "PRAGMA user_version = 1;"

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
    sqlite3_bind_int(s, int(n).cint, int(val).cint)
  elif val is int64:
    sqlite3_bind_int64(s, n.cint, val)
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

type 
  DataProc* = proc(s: ptr sqlite3_stmt) {.closure.}

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
