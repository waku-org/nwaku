# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, algorithm],
  stew/[byteutils, results],
  chronicles
import
  ../../../../../common/sqlite,
  ../../../../protocol/waku_message,
  ../../../../utils/time,
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

method close*(s: SqliteDriver): ArchiveDriverResult[void] =
  ## Close the database connection

  # Dispose statements
  s.insertStmt.dispose()

  # Close connection
  s.db.close()

  ok()


method put*(s: SqliteDriver, pubsubTopic: PubsubTopic, message: WakuMessage, digest: MessageDigest, receivedTime: Timestamp): ArchiveDriverResult[void] =
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


method getAllMessages*(s: SqliteDriver):  ArchiveDriverResult[seq[ArchiveRow]] =
  ## Retrieve all messages from the store.
  s.db.selectAllMessages()


method getMessages*(
  s: SqliteDriver,
  contentTopic: seq[ContentTopic] = @[],
  pubsubTopic = none(PubsubTopic),
  cursor = none(ArchiveCursor),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = DefaultPageSize,
  ascendingOrder = true
): ArchiveDriverResult[seq[ArchiveRow]] =
  let cursor = cursor.map(toDbCursor)

  var rows = ?s.db.selectMessagesByHistoryQueryWithLimit(
    contentTopic,
    pubsubTopic,
    cursor,
    startTime,
    endTime,
    limit=maxPageSize,
    ascending=ascendingOrder
  )

  # All messages MUST be returned in chronological order
  if not ascendingOrder:
    reverse(rows)

  ok(rows)


method getMessagesCount*(s: SqliteDriver): ArchiveDriverResult[int64] =
  s.db.getMessageCount()

method getOldestMessageTimestamp*(s: SqliteDriver): ArchiveDriverResult[Timestamp] =
  s.db.selectOldestReceiverTimestamp()

method getNewestMessageTimestamp*(s: SqliteDriver): ArchiveDriverResult[Timestamp] =
  s.db.selectnewestReceiverTimestamp()


method deleteMessagesOlderThanTimestamp*(s: SqliteDriver, ts: Timestamp): ArchiveDriverResult[void] =
  s.db.deleteMessagesOlderThanTimestamp(ts)

method deleteOldestMessagesNotWithinLimit*(s: SqliteDriver, limit: int): ArchiveDriverResult[void] =
  s.db.deleteOldestMessagesNotWithinLimit(limit)
