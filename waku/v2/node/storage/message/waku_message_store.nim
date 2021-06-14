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

  let res = prepare.value.exec((@(cursor.digest.data), cursor.receivedTime, message.contentTopic.toBytes(), message.payload, pubsubTopic.toBytes(), int64(message.version), message.timestamp))
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
      receiverTimestamp = sqlite3_column_double(s, 0)

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

      senderTimestamp = sqlite3_column_double(s, 5)


      # TODO retrieve the version number
    onData(receiverTimestamp.float64,
           WakuMessage(contentTopic: contentTopic, payload: payload , version: uint32(version), timestamp: senderTimestamp.float64), 
                       pubsubTopic)

  let res = db.database.query("SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp FROM " & TABLE_TITLE & " ORDER BY receiverTimestamp ASC", msg)
  if res.isErr:
    return err("failed")

  ok gotMessages

proc close*(db: WakuMessageStore) = 
  ## Closes the database.
  db.database.close()


proc migrate*(db: SqliteDatabase, path: string = MIGRATION_PATH, targetVersion: int64 = USER_VERSION): MessageStoreResult[bool] = 
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
    debug "scripts to be run", scripts=scripts
    
    
    proc handler(s: ptr sqlite3_stmt) = 
      discard
    
    # run the scripts
    for script in scripts:
      debug "running the script", script=script
      let res = db.query(script, handler)
      if res.isErr:
        debug "failed to run the script", script=script
        return err("failed to run the script")
    
    # bump the user version
    let res = db.setUserVersion(targetVersion)
    if res.isErr:
      return err("failed to set the new user_version")

    ok(true)
    
