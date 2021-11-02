{.push raises: [Defect].}

import 
  std/[options, tables],
  sqlite3_abi,
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
        receiverTimestamp REAL NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp REAL NOT NULL
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
    "INSERT INTO " & TABLE_TITLE & " (id, receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp) VALUES (?, ?, ?, ?, ?, ?, ?);",
    (seq[byte], float64, seq[byte], seq[byte], seq[byte], int64, float64),
    void
  )

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec((@(cursor.digest.data), cursor.receiverTime, message.contentTopic.toBytes(), message.payload, pubsubTopic.toBytes(), int64(message.version), message.timestamp))
  if res.isErr:
    return err("failed")

  ok()

method getAll*(db: WakuMessageStore, onData: message_store.DataProc, limit = none(int)): MessageStoreResult[bool] =
  ## Retrieves all messages from the storage.
  ## Optionally limits the number of rows returned.
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
      receiverTimestamp = sqlite3_column_double(s, 0)

      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      topicLength = sqlite3_column_bytes(s,1)
      contentTopic = ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicLength-1))))

      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      length = sqlite3_column_bytes(s, 2)
      payload = @(toOpenArray(p, 0, length-1))

      pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 3))
      pubsubTopicLength = sqlite3_column_bytes(s,3)
      pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength-1)))

      version = sqlite3_column_int64(s, 4)

      senderTimestamp = sqlite3_column_double(s, 5)


      # TODO retrieve the version number
    onData(receiverTimestamp.float64,
           WakuMessage(contentTopic: contentTopic, payload: payload , version: uint32(version), timestamp: senderTimestamp.float64), 
                       pubsubTopic)

  var selectQuery = "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
                    "FROM " & TABLE_TITLE & " " & 
                    "ORDER BY receiverTimestamp ASC"
  if limit.isSome():
    # Optional limit applies. This works because SQLITE will perform the time-based ORDER BY before applying the limit.
    selectQuery &= " LIMIT " & $(limit.get()) &
                   " OFFSET cast((SELECT count(*)  FROM " & TABLE_TITLE & ") AS INT) - " & $(limit.get()) # offset = total_row_count - limit
  
  let res = db.database.query(selectQuery, msg)
  if res.isErr:
    return err("failed")

  ok gotMessages

proc close*(db: WakuMessageStore) = 
  ## Closes the database.
  db.database.close()


