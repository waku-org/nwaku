import 
  os, 
  sqlite3_abi,
  chronos, chronicles, metrics, stew/results,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  stew/results, metrics,
  ../waku_types,
  ./sqlite

{.push raises: [Defect].}

# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
#
# Most of it is a direct copy, the only unique functions being `get` and `put`.

type
  DataProc* = proc(timestamp: uint64, msg: WakuMessage) {.closure.}

proc init*(T: type MessageStore): MessageStoreResult[T] =
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

  ok(MessageStore())

proc put*(db: MessageStore, cursor: Index, message: WakuMessage): MessageStoreResult[void] =
  ## Adds a message to the storage.
  ##
  ## **Example:**
  ##
  ## .. code-block::
  ##   let res = db.put(message)
  ##   if res.isErr:
  ##     echo "error"
  let s = prepare(db.env, "INSERT INTO messages (id, timestamp, contentTopic, payload) VALUES (?, ?, ?, ?);"): discard
  checkErr bindParam(s, 1, @(cursor.digest.data))
  checkErr bindParam(s, 2, int64(cursor.receivedTime))
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

proc getAll*(db: MessageStore, onData: DataProc): MessageStoreResult[bool] =
  ## Retreives all messages from the storage.
  ##
  ## **Example:**
  ##
  ## .. code-block::
  ##   proc data(timestamp: uint64, msg: WakuMessage) =
  ##     echo cast[string](msg.payload)
  ##
  ##   let res = db.get(data)
  ##   if res.isErr:
  ##     echo "error"

  let query = "SELECT timestamp, contentTopic, payload FROM messages"
  var s = prepare(db.env, query): discard

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

proc close*(db: MessageStore) = 
  db.database.close()