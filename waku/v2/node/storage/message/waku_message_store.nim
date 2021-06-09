import 
  os, sqlite3_abi, algorithm,
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

proc toBytes(x: float64): seq[byte] =
  let xbytes =  cast[array[0..7, byte]](x)
  return @xbytes

proc fromBytes(T: type float64, bytes: seq[byte]): T =
  var arr: array[0..7, byte]
  var i = 0
  for b in bytes:
    arr[i] = b
    i = i+1
    if i == 8: break
  let x = cast[float64](arr)
  return x
  
proc init*(T: type WakuMessageStore, db: SqliteDatabase): MessageStoreResult[T] =
  ## Table is the SQL query for creating the messages Table.
  ## It contains:
  ##  - 4-Byte ContentTopic stored as an Integer
  ##  - Payload stored as a blob
  let prepare = db.prepareStmt("""
    CREATE TABLE IF NOT EXISTS """ & TABLE_TITLE & """ (
        id BLOB PRIMARY KEY,
        receiverTimestamp BLOB NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp BLOB NOT NULL
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
    (seq[byte], seq[byte], seq[byte], seq[byte], seq[byte], int64, seq[byte]),
    void
  )

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec((@(cursor.digest.data), cursor.receivedTime.toBytes(), message.contentTopic.toBytes(), message.payload, pubsubTopic.toBytes(), int64(message.version), message.timestamp.toBytes()))
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
      # receiverTimestampPointer = sqlite3_column_int64(s, 0)
      receiverTimestampPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 0)) # get a pointer
      receiverTimestampL = sqlite3_column_bytes(s,0) # number of bytes
      receiverTimestampBytes = @(toOpenArray(receiverTimestampPointer, 0, receiverTimestampL-1))
      receiverTimestamp = float64.fromBytes(receiverTimestampBytes)

      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      topicL = sqlite3_column_bytes(s,1)
      contentTopic = ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicL-1))))

      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      l = sqlite3_column_bytes(s, 2)
      payload = @(toOpenArray(p, 0, l-1))

      pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 3))
      pubsubTopicL = sqlite3_column_bytes(s,3)
      pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicL-1)))

      version = sqlite3_column_int64(s, 4)

      senderTimestampPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 5))
      senderTimestampL = sqlite3_column_bytes(s,5)
      senderTimestampBytes = @(toOpenArray(senderTimestampPointer, 0, senderTimestampL-1))
      senderTimestamp = float64.fromBytes(senderTimestampBytes)

      # TODO retrieve the version number
    onData(receiverTimestamp,
           WakuMessage(contentTopic: contentTopic, payload: payload , version: uint32(version), timestamp: senderTimestamp), 
                       pubsubTopic)

  let res = db.database.query("SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp FROM " & TABLE_TITLE & " ORDER BY receiverTimestamp ASC", msg)
  if res.isErr:
    return err("failed")

  ok gotMessages

proc close*(db: WakuMessageStore) = 
  ## Closes the database.
  db.database.close()


# proc migrate*(sqlDB: SqliteDatabase, oldVersion: int64, migrationPath: string) = 
#   var env = sqlDB.env
#   var versionList: seq[string]
#   for kind, path in walkDir(migrationPath):
#     # let fileSplit = splitFile(path)
#     # versionList.add((fileSplit.name&fileSplit.ext))
#     versionList.add(path)

#     echo("Path:", path)

#   # sort migration files
#   versionList.sort()

#   for filename in versionList:
#     let query = readFile(filename)
#     echo query
#     # let prepare = sqlDB.prepareStmt(q, void, void)
#     # if prepare.isErr:
#     #   echo "failed to prepare"
    
#     template prepare(q: string): ptr sqlite3_stmt =
#       var s: ptr sqlite3_stmt
#       discard sqlite3_prepare_v2(env, q, q.len.cint, addr s, nil)
#       s

#     template checkExec(s: ptr sqlite3_stmt) =
#       if (let x = sqlite3_step(s); x != SQLITE_DONE):
#         discard sqlite3_finalize(s)
#         echo "something 1"
#         # return err($sqlite3_errstr(x))

#       if (let x = sqlite3_finalize(s); x != SQLITE_OK):
#         echo "something 2"
#         # return err($sqlite3_errstr(x))

#     template checkExec(q: string) =
#       let s = prepare(q)
#       checkExec(s)

#     # if (let x = sqlite3_step(prepare); x != SQLITE_DONE):
#     #   discard sqlite3_finalize(s)
#     #   # return err($sqlite3_errstr(x))
#     checkExec(query)



#     # var x: void
#     # let res = prepare.value.exec(x)
#     # if res.isErr:
#     #   echo "failed"

proc migrate*(database: SqliteDatabase, oldVersion: int64, migrationPath: string) = 
  var env = sqlDB.env
  var versionList: seq[string]
  for kind, path in walkDir(migrationPath):
    # let fileSplit = splitFile(path)
    # versionList.add((fileSplit.name&fileSplit.ext))
    versionList.add(path)

    echo("Path:", path)

  # sort migration files
  versionList.sort()

  for filename in versionList:
    let query = readFile(filename)
    echo query