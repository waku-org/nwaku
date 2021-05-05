import 
  sqlite3_abi,
  chronos, metrics,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  stew/[byteutils, results],
  ./message_store,
  ../sqlite,
  ../../../protocol/waku_message,
  ../../../utils/pagination

export sqlite

const TABLE_TITLE = "Message"
# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
#
# Most of it is a direct copy, the only unique functions being `get` and `put`.

type
  WakuMessageStore* = ref object of MessageStore
    database*: SqliteDatabase

proc init*(T: type WakuMessageStore, db: SqliteDatabase): MessageStoreResult[T] =
  ## Table is the SQL query for creating the messages Table.
  ## It contains:
  ##  - 4-Byte ContentTopic stored as an Integer
  ##  - Payload stored as a blob
  let prepare = db.prepareStmt("""
    CREATE TABLE IF NOT EXISTS """ & TABLE_TITLE & """ (
        id BLOB PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL
    ) WITHOUT ROWID;
    """, NoParams, void)

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec(())
  if res.isErr:
    return err("failed to exec")

  ok(WakuMessageStore(database: db))

method put*(db: WakuMessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] =
  ## Adds a message to the storage.
  ##
  ## **Example:**
  ##
  ## .. code-block::
  ##   let res = db.put(message)
  ##   if res.isErr:
  ##     echo "error"
  ## 
  let prepare = db.database.prepareStmt(
    "INSERT INTO " & TABLE_TITLE & " (id, timestamp, contentTopic, payload, pubsubTopic, version) VALUES (?, ?, ?, ?, ?, ?);",
    (seq[byte], int64, seq[byte], seq[byte], seq[byte], int64),
    void
  )

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec((@(cursor.digest.data), int64(cursor.receivedTime), message.contentTopic.toBytes(), message.payload, pubsubTopic.toBytes(), int64(message.version)))
  if res.isErr:
    return err("failed")

  ok()

method getAll*(db: WakuMessageStore, onData: message_store.DataProc): MessageStoreResult[bool] =
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
  var gotMessages = false
  proc msg(s: ptr sqlite3_stmt) = 
    gotMessages = true
    let
      timestamp = sqlite3_column_int64(s, 0)
      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      topicL = sqlite3_column_bytes(s,1)
      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      l = sqlite3_column_bytes(s, 2)
      pubsubTopic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 3))
      pubsubTopicL = sqlite3_column_bytes(s,3)
      version = sqlite3_column_int64(s, 4)

      # TODO retrieve the version number
    onData(uint64(timestamp),
           WakuMessage(contentTopic: ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicL-1)))),
                       payload: @(toOpenArray(p, 0, l-1)), version: uint32(version)), 
                       string.fromBytes(@(toOpenArray(pubsubTopic, 0, pubsubTopicL-1))))

  let res = db.database.query("SELECT timestamp, contentTopic, payload, pubsubTopic, version FROM " & TABLE_TITLE & " ORDER BY timestamp ASC", msg)
  if res.isErr:
    return err("failed")

  ok gotMessages

proc close*(db: WakuMessageStore) = 
  ## Closes the database.
  db.database.close()
