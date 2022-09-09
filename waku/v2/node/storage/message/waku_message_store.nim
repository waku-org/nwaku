# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim
{.push raises: [Defect].}

import 
  std/[options, tables, times, sequtils, algorithm],
  stew/[byteutils, results],
  chronicles,
  chronos,
  sqlite3_abi
import
  ./message_store,
  ../sqlite,
  ../../../protocol/waku_message,
  ../../../utils/pagination,
  ../../../utils/time,
  ./waku_message_store_queries

export sqlite

logScope:
  topics = "message_store.sqlite"


type
  # WakuMessageStore implements auto deletion as follows:
  #  - The sqlite DB will store up to `totalCapacity = capacity` * `StoreMaxOverflow` messages, 
  #    giving an overflowWindow of `capacity * (StoreMaxOverflow - 1) = overflowWindow`.
  #
  #  - In case of an overflow, messages are sorted by `receiverTimestamp` and the oldest ones are 
  #    deleted. The number of messages that get deleted is `(overflowWindow / 2) = deleteWindow`,
  #    bringing the total number of stored messages back to `capacity + (overflowWindow / 2)`. 
  #
  # The rationale for batch deleting is efficiency. We keep half of the overflow window in addition 
  # to `capacity` because we delete the oldest messages with respect to `receiverTimestamp` instead of 
  # `senderTimestamp`. `ReceiverTimestamp` is guaranteed to be set, while senders could omit setting 
  # `senderTimestamp`. However, `receiverTimestamp` can differ from node to node for the same message.
  # So sorting by `receiverTimestamp` might (slightly) prioritize some actually older messages and we 
  # compensate that by keeping half of the overflow window.
  WakuMessageStore* = ref object of MessageStore
    db: SqliteDatabase
    numMessages: int
    capacity: int # represents both the number of messages that are persisted in the sqlite DB (excl. the overflow window explained above), and the number of messages that get loaded via `getAll`.
    totalCapacity: int  # = capacity * StoreMaxOverflow
    deleteWindow: int   # = capacity * (StoreMaxOverflow - 1) / 2; half of the overflow window, the amount of messages deleted when overflow occurs
    isSqliteOnly: bool
    retentionTime: chronos.Duration
    oldestReceiverTimestamp: int64
    insertStmt: SqliteStmt[InsertMessageParams, void]
 

proc calculateTotalCapacity(capacity: int, overflow: float): int {.inline.} =
  int(float(capacity) * overflow)

proc calculateOverflowWindow(capacity: int, overflow: float): int {.inline.} =
  int(float(capacity) * (overflow - 1))
  
proc calculateDeleteWindow(capacity: int, overflow: float): int {.inline.} =
  calculateOverflowWindow(capacity, overflow) div 2


### Store implementation

proc deleteMessagesExceedingRetentionTime(s: WakuMessageStore): MessageStoreResult[void] =
  ## Delete messages that exceed the retention time by 10% and more (batch delete for efficiency)
  if s.oldestReceiverTimestamp == 0:
    return ok()
   
  let now = getNanosecondTime(getTime().toUnixFloat()) 
  let retentionTimestamp = now - s.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - s.retentionTime.nanoseconds div 10
  if thresholdTimestamp <= s.oldestReceiverTimestamp: 
    return ok()

  s.db.deleteMessagesOlderThanTimestamp(ts=retentionTimestamp)

proc deleteMessagesOverflowingTotalCapacity(s: WakuMessageStore): MessageStoreResult[void] =
  ?s.db.deleteOldestMessagesNotWithinLimit(limit=s.capacity + s.deleteWindow)
  info "Oldest messages deleted from db due to overflow.", capacity=s.capacity, maxStore=s.totalCapacity, deleteWindow=s.deleteWindow
  ok()


proc init*(T: type WakuMessageStore, db: SqliteDatabase, 
           capacity: int = StoreDefaultCapacity, 
           isSqliteOnly = false, 
           retentionTime = StoreDefaultRetentionTime): MessageStoreResult[T] =
  let retentionTime = seconds(retentionTime) # workaround until config.nim updated to parse a Duration
  
  ## Database initialization

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

  ## General initialization

  let
    totalCapacity = calculateTotalCapacity(capacity, StoreMaxOverflow)
    deleteWindow = calculateDeleteWindow(capacity, StoreMaxOverflow)

  let numMessages = getMessageCount(db).get()
  debug "number of messages in sqlite database", messageNum=numMessages

  let oldestReceiverTimestamp = selectOldestReceiverTimestamp(db).expect("query for oldest receiver timestamp should work")

  # Reusable prepared statement
  let insertStmt = db.prepareInsertMessageStmt()

  let wms = WakuMessageStore(
      db: db,
      capacity: capacity,
      retentionTime: retentionTime,
      isSqliteOnly: isSqliteOnly,
      totalCapacity: totalCapacity,
      deleteWindow: deleteWindow,
      insertStmt: insertStmt,
      numMessages: int(numMessages),
      oldestReceiverTimestamp: oldestReceiverTimestamp
    )


  # If the in-memory store is used and if the loaded db is already over max load,
  #  delete the oldest messages before returning the WakuMessageStore object
  if not isSqliteOnly and wms.numMessages >= wms.totalCapacity:
    let res = wms.deleteMessagesOverflowingTotalCapacity()
    if res.isErr(): 
      return err("deleting oldest messages failed: " & res.error())

    # Update oldest timestamp after deleting messages
    wms.oldestReceiverTimestamp = selectOldestReceiverTimestamp(db).expect("query for oldest timestamp should work")
    # Update message count after deleting messages
    wms.numMessages = wms.capacity + wms.deleteWindow

  # If using the sqlite-only store, delete messages exceeding the retention time
  if isSqliteOnly:
    debug "oldest message info", receiverTime=wms.oldestReceiverTimestamp

    let res = wms.deleteMessagesExceedingRetentionTime()
    if res.isErr(): 
      return err("deleting oldest messages (time) failed: " & res.error())

    # Update oldest timestamp after deleting messages
    wms.oldestReceiverTimestamp = selectOldestReceiverTimestamp(db).expect("query for oldest timestamp should work")
    # Update message count after deleting messages
    wms.numMessages = int(getMessageCount(db).expect("query for oldest timestamp should work"))

  ok(wms)


method put*(s: WakuMessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] =
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

  # If the in-memory store is used and if the loaded db is already over max load, delete the oldest messages
  if not s.isSqliteOnly and s.numMessages >= s.totalCapacity:
    let res = s.deleteMessagesOverflowingTotalCapacity()
    if res.isErr(): 
      return err("deleting oldest failed: " & res.error())
    
    # Update oldest timestamp after deleting messages
    s.oldestReceiverTimestamp = s.db.selectOldestReceiverTimestamp().expect("query for oldest timestamp should work")
    # Update message count after deleting messages
    s.numMessages = s.capacity + s.deleteWindow

  if s.isSqliteOnly:
    # TODO: move to a timer job
    # For this experimental version of the new store, it is OK to delete here, because it only actually
    # triggers the deletion if there is a batch of messages older than the threshold.
    # This only adds a few simple compare operations, if deletion is not necessary.
    # Still, the put that triggers the deletion might return with a significant delay.
    if s.oldestReceiverTimestamp == 0: 
      s.oldestReceiverTimestamp = s.db.selectOldestReceiverTimestamp().expect("query for oldest timestamp should work")

    let res = s.deleteMessagesExceedingRetentionTime()
    if res.isErr(): 
      return err("delete messages exceeding the retention time failed: " & res.error())

    # Update oldest timestamp after deleting messages
    s.oldestReceiverTimestamp = s.db.selectOldestReceiverTimestamp().expect("query for oldest timestamp should work")
    # Update message count after deleting messages
    s.numMessages = int(s.db.getMessageCount().expect("query for oldest timestamp should work"))

  ok()


method getAllMessages*(s: WakuMessageStore):  MessageStoreResult[seq[MessageStoreRow]] =
  ## Retrieve all messages from the store.
  s.db.selectAllMessages()


method getMessagesByHistoryQuery*(
  s: WakuMessageStore,
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


proc close*(s: WakuMessageStore) = 
  ## Close the database connection
  
  # Dispose statements
  s.insertStmt.dispose()

  # Close connection
  s.db.close()
