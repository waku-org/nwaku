# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import 
  std/[options, tables],
  stew/[byteutils, results],
  chronicles
import
  ../../../../common/sqlite,
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/pagination,
  ../../../protocol/waku_store/message_store,
  ../../../utils/time,
  ./queries

logScope:
  topics = "waku node message_store sqlite"


proc init(db: SqliteDatabase): MessageStoreResult[void] =
  ## Misconfiguration can lead to nil DB
  if db.isNil():
    return err("db not initialized")

  # Create table, if doesn't exist
  let resCreate = createTable(db)
  if resCreate.isErr():
    return err("failed to create table: " & resCreate.error())

  # Create indices, if don't exist
  let resRtIndex = createOldestMessageTimestampIndex(db)
  if resRtIndex.isErr():
    return err("failed to create i_rt index: " & resRtIndex.error())
  
  let resMsgIndex = createHistoryQueryIndex(db)
  if resMsgIndex.isErr():
    return err("failed to create i_msg index: " & resMsgIndex.error())

  ok()


type SqliteStore* = ref object of MessageStore
    db: SqliteDatabase
    insertStmt: SqliteStmt[InsertMessageParams, void]

proc init*(T: type SqliteStore, db: SqliteDatabase): MessageStoreResult[T] =
  
  # Database initialization
  let resInit = init(db)
  if resInit.isErr():
    return err(resInit.error())

  # General initialization
  let insertStmt = db.prepareInsertMessageStmt()
  ok(SqliteStore(db: db, insertStmt: insertStmt))

proc close*(s: SqliteStore) = 
  ## Close the database connection
  
  # Dispose statements
  s.insertStmt.dispose()

  # Close connection
  s.db.close()


method put*(s: SqliteStore, pubsubTopic: string, message: WakuMessage, digest: MessageDigest, receivedTime: Timestamp): MessageStoreResult[void] =
  ## Inserts a message into the store

  let res = s.insertStmt.exec((
    @(digest.data),                # id
    receivedTime,                  # storedAt
    toBytes(message.contentTopic), # contentTopic
    message.payload,               # payload
    toBytes(pubsubTopic),          # pubsubTopic
    int64(message.version),        # version
    message.timestamp              # senderTimestamp
  ))
  if res.isErr():
    return err("message insert failed: " & res.error)

  ok()

method put*(s: SqliteStore, pubsubTopic: string, message: WakuMessage): MessageStoreResult[void] =
  ## Inserts a message into the store
  procCall MessageStore(s).put(pubsubTopic, message)


method getAllMessages*(s: SqliteStore):  MessageStoreResult[seq[MessageStoreRow]] =
  ## Retrieve all messages from the store.
  s.db.selectAllMessages()


method getMessagesByHistoryQuery*(
  s: SqliteStore,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(PagingIndex),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = DefaultPageSize,
  ascendingOrder = true
): MessageStoreResult[seq[MessageStoreRow]] =
  let cursor = cursor.map(proc(c: PagingIndex): DbCursor = (c.receiverTime, @(c.digest.data), c.pubsubTopic))

  return s.db.selectMessagesByHistoryQueryWithLimit(
    contentTopic, 
    pubsubTopic, 
    cursor,
    startTime,
    endTime,
    limit=maxPageSize,
    ascending=ascendingOrder
  )


method getMessagesCount*(s: SqliteStore): MessageStoreResult[int64] =
  s.db.getMessageCount()

method getOldestMessageTimestamp*(s: SqliteStore): MessageStoreResult[Timestamp] =
  s.db.selectOldestReceiverTimestamp()

method getNewestMessageTimestamp*(s: SqliteStore): MessageStoreResult[Timestamp] =
  s.db.selectnewestReceiverTimestamp()


method deleteMessagesOlderThanTimestamp*(s: SqliteStore, ts: Timestamp): MessageStoreResult[void] =
  s.db.deleteMessagesOlderThanTimestamp(ts)

method deleteOldestMessagesNotWithinLimit*(s: SqliteStore, limit: int): MessageStoreResult[void] =
  s.db.deleteOldestMessagesNotWithinLimit(limit)
