# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
{.push raises: [Defect].}

import 
  std/[options, tables, sequtils, algorithm],
  stew/[byteutils, results],
  chronicles,
  chronos
import
  ../../../../protocol/waku_message,
  ../../../../utils/pagination,
  ../../../../utils/time,
  ../../sqlite,
  ../message_store,
  ./queries,
  ./retention_policy,
  ./retention_policy_capacity,
  ./retention_policy_time

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
    numMessages: int
    retentionPolicy: Option[MessageRetentionPolicy]
    insertStmt: SqliteStmt[InsertMessageParams, void]
 
proc init*(T: type SqliteStore, db: SqliteDatabase, retentionPolicy: Option[MessageRetentionPolicy]): MessageStoreResult[T] =
  
  # Database initialization
  let resInit = init(db)
  if resInit.isErr():
    return err(resInit.error())

  # General initialization
  let numMessages = getMessageCount(db).expect("get message count should succeed")
  debug "number of messages in sqlite database", messageNum=numMessages

  let insertStmt = db.prepareInsertMessageStmt()
  let s = SqliteStore(
      db: db,
      numMessages: int(numMessages),
      retentionPolicy: retentionPolicy,
      insertStmt: insertStmt,
    )

  if retentionPolicy.isSome():
    let res = retentionPolicy.get().execute(db)
    if res.isErr():
      return err("failed to execute the retention policy: " & res.error())

  ok(s)


method put*(s: SqliteStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] =
  ## Inserts a message into the store

  # Ensure that messages don't "jump" to the front with future timestamps
  if cursor.senderTime - cursor.receiverTime > StoreMaxTimeVariance:
    return err("future_sender_timestamp")

  let res = s.insertStmt.exec((
    @(cursor.digest.data),         # id
    cursor.receiverTime,           # receiverTimestamp
    toBytes(message.contentTopic), # contentTopic 
    message.payload,               # payload
    toBytes(pubsubTopic),          # pubsubTopic 
    int64(message.version),        # version
    message.timestamp              # senderTimestamp 
  ))
  if res.isErr():
    return err("message insert failed: " & res.error())

  s.numMessages += 1
  
  if s.retentionPolicy.isSome():
    let res = s.retentionPolicy.get().execute(s.db)
    if res.isErr():
      return err("failed to execute the retention policy: " & res.error())

    # Update message count after executing the retention policy
    s.numMessages =  int(s.db.getMessageCount().expect("get message count should succeed"))

  ok()


method getAllMessages*(s: SqliteStore):  MessageStoreResult[seq[MessageStoreRow]] =
  ## Retrieve all messages from the store.
  s.db.selectAllMessages()


method getMessagesByHistoryQuery*(
  s: SqliteStore,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(Index),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = StoreMaxPageSize,
  ascendingOrder = true
): MessageStoreResult[MessageStorePage] =
  let pageSizeLimit = if maxPageSize <= 0: StoreMaxPageSize
                      else: min(maxPageSize, StoreMaxPageSize)

  let rows = ?s.db.selectMessagesByHistoryQueryWithLimit(
    contentTopic, 
    pubsubTopic, 
    cursor,
    startTime,
    endTime,
    limit=pageSizeLimit,
    ascending=ascendingOrder
  )

  if rows.len <= 0:
    return ok((@[], none(PagingInfo)))

  var messages = rows.mapIt(it[0])

  # TODO: Return the message hash from the DB, to avoid recomputing the hash of the last message
  # Compute last message index
  let (message, receivedTimestamp, pubsubTopic) = rows[^1]
  let lastIndex = Index.compute(message, receivedTimestamp, pubsubTopic)

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


proc close*(s: SqliteStore) = 
  ## Close the database connection
  
  # Dispose statements
  s.insertStmt.dispose()

  # Close connection
  s.db.close()
