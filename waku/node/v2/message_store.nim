import 
    os, 
    sqlite3_abi,
    waku_types

type
  MessageStoreResult*[T] = Result[T, string]

  MessageStore* = object
    env: Sqlite

template checkErr(op, cleanup: untyped) =
  if (let v = (op); v != SQLITE_OK):
    cleanup
    return err($sqlite3_errstr(v))

template checkErr(op) =
  checkErr(op): discard

proc init*(
    T: type MessageStore,
    basePath: string,
    name: string,
    readOnly = false,
    inMemory = false): MessageStoreResult[T] =
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

  checkExec """
    CREATE TABLE IF NOT EXISTS messages (
        topic TEXT NOT NULL,
        contentTopic INTEGER NOT NULL, 
        payload BLOB NOT NULL
    );
    """

  ok(MessageStore(
    env: env.release
  ))

template prepare(q: string, cleanup: untyped): ptr sqlite3_stmt =
  var s: ptr sqlite3_stmt
  checkErr sqlite3_prepare_v2(env.val, q, q.len.cint, addr s, nil):
    cleanup
  s

proc prepareStmt*(db: MessageStore,
                  stmt: string,
                  Params: type,
                  Res: type): KvResult[SqliteStmt[Params, Res]] =
  var s: RawStmtPtr
  checkErr sqlite3_prepare_v2(db.env, stmt, stmt.len.cint, addr s, nil)
  ok SqliteStmt[Params, Res](s)

proc bindParam(s: RawStmtPtr, n: int, val: auto): cint =
  when val is openarray[byte]|seq[byte]:
    if val.len > 0:
      sqlite3_bind_blob(s, n.cint, unsafeAddr val[0], val.len.cint, nil)
    else:
      sqlite3_bind_blob(s, n.cint, nil, 0.cint, nil)
  elif val is int32:
    sqlite3_bind_int(s, n.cint, val)
  elif val is int64:
    sqlite3_bind_int64(s, n.cint, val)
  else:
    {.fatal: "Please add support for the '" & $(T) & "' type".}

proc put(db: MessageStore, message: WakuMessage): MessageStoreResult[void] =
  let stmt ? db.prepareStmt("INSERT INTO messages (topic, contentTopic, payload) VALUES (?, ?, ?)")
  checkErr bindParam(s, 1, message.topic)
  checkErr bindParam(s, 2, message.contentTopic)
  checkErr bindParam(s, 3, cast[string](msg.payload))

  ok()

proc get(db: MessageStore, topics: seq[ContentTopic]): MessageStoreResult[seq[WakuMessage]] =
  let stmt ? db.prepareStmt("SELECT contentTopic, payload FROM messages WHERE contentTopic IN (" & join(topics, ", ") & ")")

  var msgs = newSeq[WakuMessage]()

  while true:
    let
      v = sqlite3_step(stmt)
      res = case v
        of SQLITE_ROW:
          let
            topic = sqlite3_column_int(stmt, 0)
            p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(getStmt, 0))
            l = sqlite3_column_bytes(getStmt, 0)
            msg = WakuMessage(contentTopic: topic, payload: cast[string](toOpenArray(p, 0, l-1)))
          
          msgs.add(msg)
        of SQLITE_DONE:
          break
        else:
          return err($sqlite3_errstr(v))

    # release implicit transaction
  discard sqlite3_reset(stmt) # same return information as step
  discard sqlite3_clear_bindings(stmt) # no errors possible

  ok(msgs)