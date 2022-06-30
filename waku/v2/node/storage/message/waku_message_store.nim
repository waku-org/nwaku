{.push raises: [Defect].}

import 
  std/[options, tables, times],
  sqlite3_abi,
  stew/[byteutils, results],
  chronicles,
  chronos,
  ./message_store,
  ../sqlite,
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/waku_store,
  ../../../utils/pagination,
  ../../../utils/time

export sqlite

logScope:
  topics = "wakuMessageStore"

const TABLE_TITLE = "Message"
const MaxStoreOverflow = 1.3 # has to be > 1.0

# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim

type
  # WakuMessageStore implements auto deletion as follows:
  # The sqlite DB will store up to `storeMaxLoad = storeCapacity` * `MaxStoreOverflow` messages, giving an overflow window of (storeCapacity*MaxStoreOverflow - storeCapacity).
  # In case of an overflow, messages are sorted by `receiverTimestamp` and the oldest ones are deleted. The number of messages that get deleted is (overflow window / 2) = deleteWindow,
  # bringing the total number of stored messages back to `storeCapacity + (overflow window / 2)`. The rationale for batch deleting is efficiency.
  # We keep half of the overflow window in addition to `storeCapacity` because we delete the oldest messages with respect to `receiverTimestamp` instead of `senderTimestamp`.
  # `ReceiverTimestamp` is guaranteed to be set, while senders could omit setting `senderTimestamp`.
  # However, `receiverTimestamp` can differ from node to node for the same message.
  # So sorting by `receiverTimestamp` might (slightly) prioritize some actually older messages and we compensate that by keeping half of the overflow window.
  WakuMessageStore* = ref object of MessageStore
    database*: SqliteDatabase
    numMessages: int
    storeCapacity: int # represents both the number of messages that are persisted in the sqlite DB (excl. the overflow window explained above), and the number of messages that get loaded via `getAll`.
    storeMaxLoad: int  # = storeCapacity * MaxStoreOverflow
    deleteWindow: int  # = (storeCapacity * MaxStoreOverflow - storeCapacity)/2; half of the overflow window, the amount of messages deleted when overflow occurs
    isSqliteOnly: bool
    retentionTime: chronos.Duration
    oldestReceiverTimestamp: int64
    insertStmt: SqliteStmt[(seq[byte], Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp), void]
 
proc messageCount(db: SqliteDatabase): MessageStoreResult[int64] =
  var numMessages: int64
  proc handler(s: ptr sqlite3_stmt) = 
    numMessages = sqlite3_column_int64(s, 0)
  let countQuery = "SELECT COUNT(*) FROM " & TABLE_TITLE
  let countRes = db.query(countQuery, handler)
  if countRes.isErr:
    return err("failed to count number of messages in DB")
  ok(numMessages)


proc getOldestDbReceiverTimestamp(db: SqliteDatabase): MessageStoreResult[int64] =
  var oldestReceiverTimestamp: int64
  proc handler(s: ptr sqlite3_stmt) =
    oldestReceiverTimestamp = column_timestamp(s, 0)
  let query = "SELECT MIN(receiverTimestamp) FROM " & TABLE_TITLE;
  let queryRes = db.query(query, handler)
  if queryRes.isErr:
    return err("failed to get the oldest receiver timestamp from the DB")
  ok(oldestReceiverTimestamp)

proc deleteOldestTime(db: WakuMessageStore): MessageStoreResult[void] =
  # delete if there are messages in the DB that exceed the retention time by 10% and more (batch delete for efficiency)
  let retentionTimestamp = getNanosecondTime(getTime().toUnixFloat()) - db.retentionTime.nanoseconds
  let thresholdTimestamp = retentionTimestamp - db.retentionTime.nanoseconds div 10
  if thresholdTimestamp <= db.oldestReceiverTimestamp or db.oldestReceiverTimestamp == 0: return ok()

  var deleteQuery = "DELETE FROM " & TABLE_TITLE & " " &
                          "WHERE receiverTimestamp < " & $retentionTimestamp

  let res = db.database.query(deleteQuery, proc(s: ptr sqlite3_stmt) = discard)
  if res.isErr:
    return err(res.error)

  info "Messages exceeding retention time deleted from DB. ", retentionTime=db.retentionTime

  db.oldestReceiverTimestamp = db.database.getOldestDbReceiverTimestamp().expect("DB query works")

  ok()

proc deleteOldest(db: WakuMessageStore): MessageStoreResult[void] =
  var deleteQuery = "DELETE FROM " & TABLE_TITLE & " " &
                          "WHERE id NOT IN " &
                              "(SELECT id FROM " & TABLE_TITLE & " " &
                                "ORDER BY receiverTimestamp DESC " &
                                "LIMIT " & $(db.storeCapacity + db.deleteWindow) & ")"
  let res = db.database.query(deleteQuery, proc(s: ptr sqlite3_stmt) = discard)
  if res.isErr:
    return err(res.error)
  db.numMessages = db.storeCapacity + db.deleteWindow # sqlite3 DELETE does not return the number of deleted rows; Ideally we would subtract the number of actually deleted messages. We could run a separate COUNT.

  info "Oldest messages deleted from DB due to overflow.", storeCapacity=db.storeCapacity, maxStore=db.storeMaxLoad, deleteWindow=db.deleteWindow
  when defined(debug):
    let numMessages = messageCount(db.database).get() # requires another SELECT query, so only run in debug mode
    debug "Number of messages left after delete operation.", messagesLeft=numMessages

  ok()

proc init*(T: type WakuMessageStore, db: SqliteDatabase, storeCapacity: int = 50000, isSqliteOnly = false, retentionTime = chronos.days(30).seconds): MessageStoreResult[T] =
  let retentionTime = seconds(retentionTime) # workaround until config.nim updated to parse a Duration
  ## Table Creation
  let
    createStmt = db.prepareStmt("""
      CREATE TABLE IF NOT EXISTS """ & TABLE_TITLE & """ (
          id BLOB,
          receiverTimestamp """ & TIMESTAMP_TABLE_TYPE & """ NOT NULL,
          contentTopic BLOB NOT NULL,
          pubsubTopic BLOB NOT NULL,
          payload BLOB,
          version INTEGER NOT NULL,
          senderTimestamp """ & TIMESTAMP_TABLE_TYPE & """  NOT NULL,
          CONSTRAINT messageIndex PRIMARY KEY (senderTimestamp, id, pubsubTopic)
      ) WITHOUT ROWID;
      """, NoParams, void).expect("this is a valid statement")
    
  let prepareRes = createStmt.exec(())
  if prepareRes.isErr:
    return err("failed to exec")

  # We dispose of this prepared statement here, as we never use it again
  createStmt.dispose()

  ## Reusable prepared statements
  let
    insertStmt = db.prepareStmt(
      "INSERT INTO " & TABLE_TITLE & " (id, receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp) VALUES (?, ?, ?, ?, ?, ?, ?);",
      (seq[byte], Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp),
      void
    ).expect("this is a valid statement")

  ## General initialization

  let numMessages = messageCount(db).get()
  debug "number of messages in sqlite database", messageNum=numMessages

  # add index on receiverTimestamp
  let
    addIndexStmt = "CREATE INDEX IF NOT EXISTS i_rt ON " & TABLE_TITLE & "(receiverTimestamp);"
    resIndex = db.query(addIndexStmt, proc(s: ptr sqlite3_stmt) = discard)
  if resIndex.isErr:
    return err("Could not establish index on receiverTimestamp: " & resIndex.error)

  let
    storeMaxLoad = int(float(storeCapacity) * MaxStoreOverflow)
    deleteWindow = int(float(storeMaxLoad - storeCapacity) / 2)


  let wms = WakuMessageStore(database: db,
                      numMessages: int(numMessages),
                      storeCapacity: storeCapacity,
                      storeMaxLoad: storeMaxLoad,
                      deleteWindow: deleteWindow,
                      isSqliteOnly: isSqliteOnly,
                      retentionTime: retentionTime,
                      oldestReceiverTimestamp: db.getOldestDbReceiverTimestamp().expect("DB query for oldest receiver timestamp works."),
                      insertStmt: insertStmt)

  # if the in-memory store is used and if the loaded db is already over max load, delete the oldest messages before returning the WakuMessageStore object
  if not isSqliteOnly and wms.numMessages >= wms.storeMaxLoad:
    let res = wms.deleteOldest()
    if res.isErr: return err("deleting oldest messages failed: " & res.error())

  # if using the sqlite-only store, delete messages exceeding the retention time
  if isSqliteOnly:
    debug "oldest message info", receiverTime=wms.oldestReceiverTimestamp
    let res = wms.deleteOldestTime()
    if res.isErr: return err("deleting oldest messages (time) failed: " & res.error())

  ok(wms)


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

  let res = db.insertStmt.exec((@(cursor.digest.data), cursor.receiverTime, message.contentTopic.toBytes(), message.payload, pubsubTopic.toBytes(), int64(message.version), message.timestamp))
  if res.isErr:
    return err("failed")

  db.numMessages += 1
  # if the in-memory store is used and if the loaded db is already over max load, delete the oldest messages
  if not db.isSqliteOnly and db.numMessages >= db.storeMaxLoad:
    let res = db.deleteOldest()
    if res.isErr: return err("deleting oldest failed")

  if db.isSqliteOnly:
    # TODO: move to a timer job
    # For this experimental version of the new store, it is OK to delete here, because it only actually triggers the deletion if there is a batch of messages older than the threshold.
    # This only adds a few simple compare operations, if deletion is not necessary.
    # Still, the put that triggers the deletion might return with a significant delay.
    if db.oldestReceiverTimestamp == 0: db.oldestReceiverTimestamp = db.database.getOldestDbReceiverTimestamp().expect("DB query for oldest receiver timestamp works.")
    let res = db.deleteOldestTime()
    if res.isErr: return err("deleting oldest failed")

  ok()

method getAll*(db: WakuMessageStore, onData: message_store.DataProc): MessageStoreResult[bool] =
  ## Retrieves `storeCapacity` many  messages from the storage.
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
      receiverTimestamp = column_timestamp(s, 0)

      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      topicLength = sqlite3_column_bytes(s,1)
      contentTopic = ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicLength-1))))

      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      length = sqlite3_column_bytes(s, 2)
      payload = @(toOpenArray(p, 0, length-1))

      pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 3))
      pubsubTopicLength = sqlite3_column_bytes(s,3)
      pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength-1)))

      version = sqlite3_column_int64(s, 4)

      senderTimestamp = column_timestamp(s, 5)


      # TODO retrieve the version number
    onData(Timestamp(receiverTimestamp),
           WakuMessage(contentTopic: contentTopic, payload: payload , version: uint32(version), timestamp: Timestamp(senderTimestamp)), 
                       pubsubTopic)

  var selectQuery = "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
                    "FROM " & TABLE_TITLE & " " & 
                    "ORDER BY receiverTimestamp ASC"

  # Apply limit. This works because SQLITE will perform the time-based ORDER BY before applying the limit.
  selectQuery &= " LIMIT " & $db.storeCapacity &
                 " OFFSET cast((SELECT count(*)  FROM " & TABLE_TITLE & ") AS INT) - " & $db.storeCapacity # offset = total_row_count - limit
  
  let res = db.database.query(selectQuery, msg)
  if res.isErr:
    return err(res.error)

  ok gotMessages

proc adjustDbPageSize(dbPageSize: uint64, matchCount: uint64, returnPageSize: uint64): uint64 {.inline.} =
  const maxDbPageSize: uint64 = 20000 # the maximum DB page size is limited to prevent excessive use of memory in case of very sparse or non-matching filters. TODO: dynamic, adjust to available memory
  if dbPageSize >= maxDbPageSize: 
    return maxDbPageSize
  var ret =
    if matchCount < 2: dbPageSize * returnPageSize
    else: dbPageSize * (returnPageSize div matchCount)
  ret = min(ret, maxDbPageSize)
  trace "dbPageSize adjusted to: ",  ret
  ret


method getPage*(db: WakuMessageStore,
              pred: QueryFilterMatcher,
              pagingInfo: PagingInfo):
             MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] =
  ## Get a single page of history matching the predicate and
  ## adhering to the pagingInfo parameters
  
  trace "getting page from SQLite DB", pagingInfo=pagingInfo

  let
    responsePageSize = if pagingInfo.pageSize == 0 or pagingInfo.pageSize > MaxPageSize: MaxPageSize # Used default MaxPageSize for invalid pagingInfos
                  else: pagingInfo.pageSize

  var dbPageSize = responsePageSize  # we retrieve larger pages from the DB for queries with (sparse) filters (TODO: improve adaptive dbPageSize increase)

  var cursor = pagingInfo.cursor

  var messages: seq[WakuMessage]
  var
    lastIndex: Index
    numRecordsVisitedPage: uint64 = 0  # number of DB records visited during retrieving the last page from the DB
    numRecordsVisitedTotal: uint64 = 0 # number of DB records visited in total
    numRecordsMatchingPred: uint64 = 0 # number of records that matched the predicate on the last DB page; we use this as to gauge the sparseness of rows matching the filter.

  proc msg(s: ptr sqlite3_stmt) = # this is the actual onData proc that is passed to the query proc (the message store adds one indirection)
    if uint64(messages.len) >= responsePageSize: return
    let
      receiverTimestamp = column_timestamp(s, 0)

      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      topicLength = sqlite3_column_bytes(s,1)
      contentTopic = ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicLength-1))))

      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      length = sqlite3_column_bytes(s, 2)
      payload = @(toOpenArray(p, 0, length-1))

      pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 3))
      pubsubTopicLength = sqlite3_column_bytes(s,3)
      pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength-1)))

      version = sqlite3_column_int64(s, 4)

      senderTimestamp = column_timestamp(s, 5)
      retMsg = WakuMessage(contentTopic: contentTopic, payload: payload, version: uint32(version), timestamp: Timestamp(senderTimestamp))
      # TODO: we should consolidate WakuMessage, Index, and IndexedWakuMessage; reason: avoid unnecessary copying and recalculation
      index = retMsg.computeIndex(receiverTimestamp, pubsubTopic) # TODO: retrieve digest from DB
      indexedWakuMsg = IndexedWakuMessage(msg: retMsg, index: index, pubsubTopic: pubsubTopic) # TODO: constructing indexedWakuMsg requires unnecessary copying

    lastIndex = index
    numRecordsVisitedPage += 1
    try:
      if pred(indexedWakuMsg): #TODO throws unknown exception
        numRecordsMatchingPred += 1
        messages.add(retMsg)
    except:
      # TODO properly handle this exception
      quit 1

  # TODO: deduplicate / condense the following 4 DB query strings
  # If no index has been set in pagingInfo, start with the first message (or the last in case of backwards direction)
  if cursor == Index(): ## TODO: pagingInfo.cursor should be an Option. We shouldn't rely on empty initialisation to determine if set or not!
    let noCursorQuery =
      if pagingInfo.direction == PagingDirection.FORWARD:
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "ORDER BY senderTimestamp, id, pubsubTopic, receiverTimestamp " &
        "LIMIT " & $dbPageSize & ";"
      else:
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "ORDER BY senderTimestamp DESC, id DESC, pubsubTopic DESC, receiverTimestamp DESC " &
        "LIMIT " & $dbPageSize & ";"

    let res = db.database.query(noCursorQuery, msg)
    if res.isErr:
      return err("failed to execute SQLite query: noCursorQuery")
    numRecordsVisitedTotal = numRecordsVisitedPage
    numRecordsVisitedPage = 0
    dbPageSize = adjustDbPageSize(dbPageSize, numRecordsMatchingPred, responsePageSize)
    numRecordsMatchingPred = 0
    cursor = lastIndex

  let preparedPageQuery = if pagingInfo.direction == PagingDirection.FORWARD:
      db.database.prepareStmt(
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "WHERE (senderTimestamp, id, pubsubTopic) > (?, ?, ?) " &
        "ORDER BY senderTimestamp, id, pubsubTopic, receiverTimestamp " &
        "LIMIT ?;",
        (Timestamp, seq[byte], seq[byte], int64), # TODO: uint64 not supported yet
        (Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp),
      ).expect("this is a valid statement")
    else:
      db.database.prepareStmt(
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "WHERE (senderTimestamp, id, pubsubTopic) < (?, ?, ?) " &
        "ORDER BY senderTimestamp DESC, id DESC, pubsubTopic DESC, receiverTimestamp DESC " &
        "LIMIT ?;",
        (Timestamp, seq[byte], seq[byte], int64),
        (Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp),
      ).expect("this is a valid statement")


  # TODO: DoS attack mitigation against: sending a lot of queries with sparse (or non-matching) filters making the store node run through the whole DB. Even worse with pageSize = 1.
  while uint64(messages.len) < responsePageSize:
    let res = preparedPageQuery.exec((cursor.senderTime, @(cursor.digest.data), cursor.pubsubTopic.toBytes(), dbPageSize.int64), msg) # TODO support uint64, pages large enough to cause an overflow are not expected...
    if res.isErr:
      return err("failed to execute SQLite prepared statement: preparedPageQuery")
    numRecordsVisitedTotal += numRecordsVisitedPage
    if numRecordsVisitedPage == 0: break # we are at the end of the DB (find more efficient/integrated solution to track that event)
    numRecordsVisitedPage = 0
    cursor = lastIndex
    dbPageSize = adjustDbPageSize(dbPageSize, numRecordsMatchingPred, responsePageSize)
    numRecordsMatchingPred = 0

  let outPagingInfo = PagingInfo(pageSize: messages.len.uint,
                             cursor: lastIndex,
                             direction: pagingInfo.direction)

  let historyResponseError = if numRecordsVisitedTotal == 0: HistoryResponseError.INVALID_CURSOR # Index is not in DB (also if queried Index points to last entry)
    else: HistoryResponseError.NONE

  preparedPageQuery.dispose()

  return ok((messages, outPagingInfo, historyResponseError)) # TODO: historyResponseError is not a "real error": treat as a real error




method getPage*(db: WakuMessageStore,
              pagingInfo: PagingInfo):
             MessageStoreResult[(seq[WakuMessage], PagingInfo, HistoryResponseError)] =
  ## Get a single page of history without filtering.
  ## Adhere to the pagingInfo parameters
  
  proc predicate(i: IndexedWakuMessage): bool = true # no filtering

  return getPage(db, predicate, pagingInfo)




proc close*(db: WakuMessageStore) = 
  ## Closes the database.
  db.insertStmt.dispose()
  db.database.close()
