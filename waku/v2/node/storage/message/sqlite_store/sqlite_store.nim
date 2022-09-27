# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
{.push raises: [Defect].}

import 
  std/[options, tables, sequtils, algorithm, times],
  stew/[byteutils, results],
  chronicles
import
  ../../../../protocol/waku_message,
  ../../../../utils/pagination,
  ../../../../utils/time,
  ../../sqlite,
  ../message_store,
  ./queries

logScope:
  topics = "message_store.sqlite"


proc init(db: SqliteDatabase): MessageStoreResult[void] =
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
    return err("message insert failed: " & res.error())

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
): MessageStoreResult[MessageStorePage] =

  let rows = ?s.db.selectMessagesByHistoryQueryWithLimit(
    contentTopic, 
    pubsubTopic, 
    cursor,
    startTime,
    endTime,
    limit=maxPageSize,
    ascending=ascendingOrder
  )

  if rows.len <= 0:
    return ok((@[], none(PagingInfo)))

  var messages = rows.mapIt(it[0])

  # TODO: Return the message hash from the DB, to avoid recomputing the hash of the last message
  # Compute last message index
  let (message, storedAt, pubsubTopic) = rows[^1]
  let lastIndex = PagingIndex.compute(message, storedAt, pubsubTopic)

  let pagingInfo = PagingInfo(
    pageSize: uint64(messages.len),
    cursor: lastIndex,
    direction: if ascendingOrder: PagingDirection.FORWARD
               else: PagingDirection.BACKWARD
  )

  # The retrieved messages list should always be in chronological order
  if not ascendingOrder:
    messages.reverse()

  ok((messages, some(pagingInfo)))


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
