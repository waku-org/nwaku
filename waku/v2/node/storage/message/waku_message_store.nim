{.push raises: [Defect].}

import 
  std/[os, algorithm, tables, strutils],
  chronos, metrics, chronicles,
  sqlite3_abi,
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
    "INSERT INTO " & TABLE_TITLE & " (id, contentTopic, payload, pubsubTopic, version, senderTimestamp) VALUES (?, ?, ?, ?, ?, ?);",
    (seq[byte], seq[byte], seq[byte], seq[byte], int64, float64),
    void
  )

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec((@(cursor.digest.data), message.contentTopic.toBytes(), message.payload, pubsubTopic.toBytes(), int64(message.version), message.timestamp))
  if res.isErr:
    return err("failed")

  ok()

method getAll*(db: WakuMessageStore, onData: message_store.DataProc): MessageStoreResult[bool] {.raises: [Defect, Exception].} =
  ## Retrieves all messages from the storage.
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
  proc msg(s: ptr sqlite3_stmt) {.raises: [Defect, Exception].} =
    gotMessages = true
    let
      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 0))
      topicLength = sqlite3_column_bytes(s,0)
      contentTopic = ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicLength-1))))

      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      length = sqlite3_column_bytes(s, 1)
      payload = @(toOpenArray(p, 0, length-1))

      pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      pubsubTopicLength = sqlite3_column_bytes(s,2)
      pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength-1)))

      version = sqlite3_column_int64(s, 3)

      senderTimestamp = sqlite3_column_double(s, 4)


      # TODO retrieve the version number
    onData(WakuMessage(contentTopic: contentTopic, payload: payload , version: uint32(version), timestamp: senderTimestamp.float64), 
                       pubsubTopic)

  let res = db.database.query("SELECT contentTopic, payload, pubsubTopic, version, senderTimestamp FROM " & TABLE_TITLE & " ORDER BY senderTimestamp ASC", msg)
  if res.isErr:
    return err("failed")

  ok gotMessages

proc close*(db: WakuMessageStore) = 
  ## Closes the database.
  db.database.close()

    
