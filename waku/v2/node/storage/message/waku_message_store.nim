{.push raises: [Defect].}

import 
  os, sqlite3_abi, algorithm, tables, strutils,
  chronos, metrics, chronicles,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  stew/[byteutils, results],
  ./message_store,
  ../sqlite,
  ../migration/[migration_types,migration_utils],
  ../../../protocol/waku_message,
  ../../../utils/pagination 
export sqlite

const TABLE_TITLE = "Message"
const USER_VERSION = 2 # increase this when there is a breaking change in the table schema
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const MIGRATION_PATH = sourceDir / "../migration/migrations_scripts/message"

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


proc migrate*(db: SqliteDatabase, path: string = MIGRATION_PATH, tragetVersion: int64 = USER_VERSION): MessageStoreResult[bool] = 
  ## checks the user_versions of the db and runs migration scripts of the higher versions (does not support down migration)
  ## path points to the directory holding the migrations scripts
  ## once the db is updated, it sets the user_version to the tragetVersion
  
  # read database version
  let userVersion = db.getUserVerion()
  debug "current db user_version", userVersion=userVersion
  if userVersion.value == tragetVersion:
    # already up to date
    info "database is up to date"
    ok(true)
  
  else:
    # TODO check for the down migrations i.e., userVersion.value > tragetVersion
    # fetch migration scripts
    let migrationScriptsRes = getMigrationScripts(path)
    if migrationScriptsRes.isErr:
      return err("failed to load migration scripts")
    let migrationScripts = migrationScriptsRes.value

    # filter scripts that are higher than the current db version
    let scriptsRes = filterMigrationScripts(migrationScripts, userVersion.value)
    if scriptsRes.isErr:
      return err("failed to fetch migration scripts")
    
    let scripts = scriptsRes.value
    info "scripts to be run", scripts=scripts
    
    
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
    let res = db.setUserVerion(tragetVersion)
    if res.isErr:
      return err("failed to set the new user_version")

    ok(true)
    
