# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/[byteutils, results],
  chronicles,
  chronos
import
  ../../../common/databases/db_sqlite,
  ../../../waku_core,
  ../../../waku_core/message/digest,
  ../../common,
  ../../driver,
  ./cursor,
  ./queries

logScope:
  topics = "waku archive sqlite"

proc init(db: SqliteDatabase): ArchiveDriverResult[void] =
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

type SqliteDriver* = ref object of ArchiveDriver
    db: SqliteDatabase
    insertStmt: SqliteStmt[InsertMessageParams, void]

proc new*(T: type SqliteDriver, db: SqliteDatabase): ArchiveDriverResult[T] =

  # Database initialization
  let resInit = init(db)
  if resInit.isErr():
    return err(resInit.error())

  # General initialization
  let insertStmt = db.prepareInsertMessageStmt()
  ok(SqliteDriver(db: db, insertStmt: insertStmt))

method put*(s: SqliteDriver,
            pubsubTopic: PubsubTopic,
            message: WakuMessage,
            digest: MessageDigest,
            messageHash: WakuMessageHash,
            receivedTime: Timestamp):
            Future[ArchiveDriverResult[void]] {.async.} =
  ## Inserts a message into the store
  let res = s.insertStmt.exec((
    @(digest.data),                # id
    @(messageHash),                # messageHash
    receivedTime,                  # storedAt
    toBytes(message.contentTopic), # contentTopic
    message.payload,               # payload
    toBytes(pubsubTopic),          # pubsubTopic
    int64(message.version),        # version
    message.timestamp              # senderTimestamp
  ))

  return res

method getAllMessages*(s: SqliteDriver):
                       Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## Retrieve all messages from the store.
  return s.db.selectAllMessages()

method getMessages*(s: SqliteDriver,
                    contentTopic: seq[ContentTopic] = @[],
                    pubsubTopic = none(PubsubTopic),
                    cursor = none(ArchiveCursor),
                    startTime = none(Timestamp),
                    endTime = none(Timestamp),
                    maxPageSize = DefaultPageSize,
                    ascendingOrder = true):
                    Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =

  let cursor = cursor.map(toDbCursor)

  let rowsRes = s.db.selectMessagesByHistoryQueryWithLimit(
    contentTopic,
    pubsubTopic,
    cursor,
    startTime,
    endTime,
    limit=maxPageSize,
    ascending=ascendingOrder
  )

  return rowsRes

method getMessagesCount*(s: SqliteDriver):
                         Future[ArchiveDriverResult[int64]] {.async.} =
  return s.db.getMessageCount()

method getPagesCount*(s: SqliteDriver):
                         Future[ArchiveDriverResult[int64]] {.async.} =
  return s.db.getPageCount()

method getPagesSize*(s: SqliteDriver):
                         Future[ArchiveDriverResult[int64]] {.async.} =
  return s.db.getPageSize()

method performVacuum*(s: SqliteDriver):
                         Future[ArchiveDriverResult[void]] {.async.} =
  return s.db.performSqliteVacuum()

method getOldestMessageTimestamp*(s: SqliteDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return s.db.selectOldestReceiverTimestamp()

method getNewestMessageTimestamp*(s: SqliteDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return s.db.selectnewestReceiverTimestamp()

method deleteMessagesOlderThanTimestamp*(s: SqliteDriver,
                                         ts: Timestamp):
                                         Future[ArchiveDriverResult[void]] {.async.} =
  return s.db.deleteMessagesOlderThanTimestamp(ts)

method deleteOldestMessagesNotWithinLimit*(s: SqliteDriver,
                                           limit: int):
                                           Future[ArchiveDriverResult[void]] {.async.} =
  return s.db.deleteOldestMessagesNotWithinLimit(limit)

method close*(s: SqliteDriver):
              Future[ArchiveDriverResult[void]] {.async.} =
  ## Close the database connection
  # Dispose statements
  s.insertStmt.dispose()
  # Close connection
  s.db.close()
  return ok()

