import 
  os, 
  sqlite3_abi,
  waku_types,
  chronos, chronicles, metrics, stew/results,
  libp2p/switch,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  stew/results, metrics,
  strutils, sequtils, times

{.push raises: [Defect].}

# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
#
# Most of it is a direct copy, the only unique functions being `get` and `put`.

type
  RawStmtPtr = ptr sqlite3_stmt

  AutoDisposed[T: ptr|ref] = object
    val: T

  DataProc* = proc(timestamp: uint64, msg: WakuMessage) {.closure.} 

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

template checkErr(op, cleanup: untyped) =
  if (let v = (op); v != SQLITE_OK):
    cleanup
    return err($sqlite3_errstr(v))

template checkErr(op) =
  checkErr(op): discard

proc init*(
    T: type MessageStore,
    basePath: string,
    name: string = "store",
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

  ## Table is the SQL query for creating the messages Table.
  ## It contains:
  ##  - 4-Byte ContentTopic stored as an Integer
  ##  - Payload stored as a blob
  checkExec """
    CREATE TABLE IF NOT EXISTS messages (
        id BLOB PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        contentTopic INTEGER NOT NULL, 
        payload BLOB
    ) WITHOUT ROWID;
    """

  ok(MessageStore(
    env: env.release
  ))

template prepare(env: Sqlite, q: string, cleanup: untyped): ptr sqlite3_stmt =
  var s: ptr sqlite3_stmt
  checkErr sqlite3_prepare_v2(env, q, q.len.cint, addr s, nil):
    cleanup
  s

proc bindParam(s: RawStmtPtr, n: int, val: auto): cint =
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
  else:
    {.fatal: "Please add support for the 'kek' type".}

proc put*(db: MessageStore, message: WakuMessage): MessageStoreResult[void] =
  ## Adds a message to the storage.
  ##
  ## **Example:**
  ##
  ## .. code-block::
  ##   let res = db.put(message)
  ##   if res.isErr:
  ##     echo "error"
  let s = prepare(db.env, "INSERT INTO messages (id, timestamp, contentTopic, payload) VALUES (?, ?, ?, ?);"): discard
  checkErr bindParam(s, 1, @(message.id().data))
  checkErr bindParam(s, 2, toUnix(now().toTime))
  checkErr bindParam(s, 3, message.contentTopic)
  checkErr bindParam(s, 4, message.payload)

  let res =
    if (let v = sqlite3_step(s); v != SQLITE_DONE):
      err($sqlite3_errstr(v))
    else:
      ok()

  # release implict transaction
  discard sqlite3_reset(s) # same return information as step
  discard sqlite3_clear_bindings(s) # no errors possible

  res

proc close*(db: MessageStore) =
  discard sqlite3_close(db.env)

  db[] = MessageStore()[]

proc get*(db: MessageStore, topics: seq[ContentTopic], paging: PagingInfo, onData: DataProc): MessageStoreResult[bool] =
  ## Retreives a message from the storage.
  ##
  ## **Example:**
  ##
  ## .. code-block::
  ##   proc data(msg: WakuMessage) =
  ##     echo cast[string](msg.payload)
  ##
  ##   let res = db.get(topics, paging, data)
  ##   if res.isErr:
  ##     echo "error"

  var s: ptr sqlite3_stmt

  let pageSize = 
    if paging.pageSize > 0 and paging.pageSize > MaxPageSize:
      MaxPageSize
    else:
      paging.pageSize 

  if paging.cursor == Index():
    let order =
      case paging.direction
        of FORWARD:
          "ORDER BY timestamp ASC, id ASC"
        of BACKWARD:
          "ORDER BY timestamp DESC, id DESC"

    var query = "SELECT timestamp, contentTopic, payload FROM messages WHERE contentTopic IN (" & join(topics, ", ") & ") " & order

    if pageSize > 0:
      query &= " LIMIT " & $pageSize

    s = prepare(db.env, query): discard
  else:
    let order =
      case paging.direction
        of FORWARD:
          "ORDER BY timestamp ASC, id ASC"
        of BACKWARD:
          "ORDER BY timestamp DESC, id DESC"

    let where =
      case paging.direction
        of FORWARD:
          "AND timestamp > ?"
        of BACKWARD:
          "AND timestamp < ?"

    var query = "SELECT timestamp, contentTopic, payload FROM messages WHERE contentTopic IN (" & join(topics, ", ") & ") " & where & " " & order

    if pageSize > 0:
      query &= " LIMIT " & $pageSize

    s = prepare(db.env, query): discard
    checkErr bindParam(s, 1, int64(paging.cursor.receivedTime))

  try:
    var gotResults = false
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        let
          timestamp = sqlite3_column_int64(s, 0)
          topic = sqlite3_column_int(s, 1)
          p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
          l = sqlite3_column_bytes(s, 2)

        onData(uint64(timestamp), WakuMessage(contentTopic: ContentTopic(int(topic)), payload: @(toOpenArray(p, 0, l-1))))
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
