{.push raises: [Defect].}

import
  std/[options, sequtils],
  stew/[results, byteutils],
  sqlite3_abi
import
  ../sqlite, 
  ../../../protocol/waku_message,
  ../../../utils/pagination,
  ../../../utils/time


const DbTable = "Message"

type SqlQueryStr = string


### SQLite column helper methods

proc queryRowWakuMessageCallback(s: ptr sqlite3_stmt, contentTopicCol, payloadCol, versionCol, senderTimestampCol: cint): WakuMessage {.inline.} =
  let 
    topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, contentTopicCol))
    topicLength = sqlite3_column_bytes(s, 1)
    contentTopic = string.fromBytes(@(toOpenArray(topic, 0, topicLength-1)))
  let
    p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, payloadCol))
    length = sqlite3_column_bytes(s, 2)
    payload = @(toOpenArray(p, 0, length-1))
  let version = sqlite3_column_int64(s, versionCol)
  let senderTimestamp = sqlite3_column_int64(s, senderTimestampCol)

  WakuMessage(
    contentTopic: ContentTopic(contentTopic), 
    payload: payload , 
    version: uint32(version), 
    timestamp: Timestamp(senderTimestamp)
  ) 

proc queryRowReceiverTimestampCallback(s: ptr sqlite3_stmt, receiverTimestampCol: cint): Timestamp {.inline.} =
  let receiverTimestamp = sqlite3_column_int64(s, receiverTimestampCol)
  Timestamp(receiverTimestamp)

proc queryRowPubsubTopicCallback(s: ptr sqlite3_stmt, pubsubTopicCol: cint): string {.inline.} =
  let
    pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, pubsubTopicCol))
    pubsubTopicLength = sqlite3_column_bytes(s, 3)
    pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength-1)))

  pubsubTopic



### SQLite queries

## Create table

template createTableQuery(table: string): SqlQueryStr = 
  "CREATE TABLE IF NOT EXISTS " & table & " (" &
  " id BLOB," &
  " receiverTimestamp INTEGER NOT NULL," &
  " contentTopic BLOB NOT NULL," &
  " pubsubTopic BLOB NOT NULL," &
  " payload BLOB," &
  " version INTEGER NOT NULL," &
  " senderTimestamp INTEGER NOT NULL," &
  " CONSTRAINT messageIndex PRIMARY KEY (senderTimestamp, id, pubsubTopic)" &
  ") WITHOUT ROWID;"

proc createTable*(db: SqliteDatabase): DatabaseResult[void] {.inline.} =
  let query = createTableQuery(DbTable)
  discard ?db.query(query, proc(s: ptr sqlite3_stmt) = discard)
  ok()


## Create index

template createIndexQuery(table: string): SqlQueryStr = 
  "CREATE INDEX IF NOT EXISTS i_rt ON " & table & " (receiverTimestamp);"

proc createIndex*(db: SqliteDatabase): DatabaseResult[void] {.inline.} =
  let query = createIndexQuery(DbTable)
  discard ?db.query(query, proc(s: ptr sqlite3_stmt) = discard)
  ok()


## Insert message
type InsertMessageParams* = (seq[byte], Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp)

template insertMessageQuery(table: string): SqlQueryStr =
  "INSERT INTO " & table & "(id, receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp)" &
  " VALUES (?, ?, ?, ?, ?, ?, ?);"
  
proc prepareInsertMessageStmt*(db: SqliteDatabase): SqliteStmt[InsertMessageParams, void] =
  let query = insertMessageQuery(DbTable)
  db.prepareStmt( query, InsertMessageParams, void).expect("this is a valid statement")


## Count table messages

template countMessagesQuery(table: string): SqlQueryStr =
  "SELECT COUNT(*) FROM " & table

proc getMessageCount*(db: SqliteDatabase): DatabaseResult[int64] {.inline.} =
  var count: int64
  proc queryRowCallback(s: ptr sqlite3_stmt) = 
    count = sqlite3_column_int64(s, 0)

  let query = countMessagesQuery(DbTable)
  let res = db.query(query, queryRowCallback)
  if res.isErr():
    return err("failed to count number of messages in the database")

  ok(count)


## Get oldest receiver timestamp

template selectOldestMessageTimestampQuery(table: string): SqlQueryStr =
  "SELECT MIN(receiverTimestamp) FROM " & table

proc selectOldestReceiverTimestamp*(db: SqliteDatabase): DatabaseResult[Timestamp] {.inline.}=
  var timestamp: Timestamp
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    timestamp = queryRowReceiverTimestampCallback(s, 0)

  let query = selectOldestMessageTimestampQuery(DbTable)
  let res = db.query(query, queryRowCallback)
  if res.isErr():
    return err("failed to get the oldest receiver timestamp from the database")

  ok(timestamp)


## Delete messages older than timestamp

template deleteMessagesOlderThanTimestampQuery(table: string, ts: Timestamp): SqlQueryStr =
  "DELETE FROM " & table & " WHERE receiverTimestamp < " & $ts

proc deleteMessagesOlderThanTimestamp*(db: SqliteDatabase, ts: int64): DatabaseResult[void] {.inline.} =
  let query = deleteMessagesOlderThanTimestampQuery(DbTable, ts)
  discard ?db.query(query, proc(s: ptr sqlite3_stmt) = discard)
  ok()


## Delete oldest messages not within limit

template deleteOldestMessagesNotWithinLimitQuery*(table: string, limit: int): SqlQueryStr =
  "DELETE FROM " & table & " WHERE id NOT IN (" &
  " SELECT id FROM " & table & 
  " ORDER BY receiverTimestamp DESC" &
  " LIMIT " & $limit &
  ");"

proc deleteOldestMessagesNotWithinLimit*(db: SqliteDatabase, limit: int): DatabaseResult[void] {.inline.} = 
  # NOTE: The word `limit` here refers the store capacity/maximum number-of-messages allowed limit
  let query = deleteOldestMessagesNotWithinLimitQuery(DbTable, limit=limit)
  discard ?db.query(query, proc(s: ptr sqlite3_stmt) = discard)
  ok()


## Select all messages

template selectAllMessagesQuery(table: string): SqlQueryStr =
  "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp" &
  " FROM " & table &
  " ORDER BY receiverTimestamp ASC"

proc selectAllMessages*(db: SqliteDatabase): DatabaseResult[seq[(Timestamp, WakuMessage, string)]] =
  ## Retrieve all messages from the store.
  var rows: seq[(Timestamp, WakuMessage, string)]
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    let
      receiverTimestamp = queryRowReceiverTimestampCallback(s, receiverTimestampCol=0)
      wakuMessage = queryRowWakuMessageCallback(s, contentTopicCol=1, payloadCol=2, versionCol=4, senderTimestampCol=5)
      pubsubTopic = queryRowPubsubTopicCallback(s, pubsubTopicCol=3)

    rows.add((receiverTimestamp, wakuMessage, pubsubTopic))

  let query = selectAllMessagesQuery(DbTable)
  let res = db.query(query, queryRowCallback)
  if res.isErr():
    return err(res.error())

  ok(rows)


## Select messages by history query with limit

proc contentTopicWhereClause(contentTopic: Option[seq[ContentTopic]]): Option[string] =
  if contentTopic.isNone():
    return none(string)

  let topic = contentTopic.get()
  if topic.len <= 0:
    return none(string)

  var contentTopicWhere = "(" 
  contentTopicWhere &= "contentTopic = (?)"
  for _ in topic[1..^1]:
    contentTopicWhere &= " OR contentTopic = (?)"
  contentTopicWhere &= ")"
  some(contentTopicWhere)

proc cursorWhereClause(cursor: Option[Index], ascending=true): Option[string] =
  if cursor.isNone():
    return none(string)

  let comp = if ascending: ">" else: "<"
  let whereClause = "(senderTimestamp, id, pubsubTopic) " & comp & " (?, ?, ?)"
  some(whereClause)

proc pubsubWhereClause(pubsubTopic: Option[string]): Option[string] =
  if pubsubTopic.isNone():
    return none(string)

  some("pubsubTopic = (?)")

proc timeRangeWhereClause(startTime: Option[Timestamp], endTime: Option[Timestamp]): Option[string] =
  if startTime.isNone() and endTime.isNone():
    return none(string)

  var where = "("
  if startTime.isSome():
    where &= "senderTimestamp >= (?)"
  if startTime.isSome() and endTime.isSome():
    where &= " AND "
  if endTime.isSome():
    where &= "senderTimestamp <= (?)"
  where &= ")"
  some(where)

proc whereClause(clauses: varargs[Option[string]]): Option[string] =
  if clauses.len <= 0 or @clauses.all(proc(clause: Option[string]): bool= clause.isNone()):
    return none(string)
  
  let whereList = @clauses
    .filter(proc(clause: Option[string]): bool= clause.isSome())
    .map(proc(clause: Option[string]): string = clause.get())

  var where: string = whereList[0]
  for clause in whereList[1..^1]:
    where &= " AND " & clause
  some(where) 

proc selectMessagesWithLimitQuery(table: string, where: Option[string], limit: uint64, ascending=true): SqlQueryStr =
  let order = if ascending: "ASC" else: "DESC"

  var query: string

  query = "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp"
  query &= " FROM " & table
  
  if where.isSome():
    query &= " WHERE " & where.get()
  
  query &= " ORDER BY senderTimestamp " & order & ", id " & order & ", pubsubTopic " & order & ", receiverTimestamp " & order 
  query &= " LIMIT " & $limit & ";"

  query

proc prepareSelectMessagesWithlimitStmt(db: SqliteDatabase, stmt: string): DatabaseResult[SqliteStmt[void, void]] =
  var s: RawStmtPtr
  checkErr sqlite3_prepare_v2(db.env, stmt, stmt.len.cint, addr s, nil)
  ok(SqliteStmt[void, void](s))

proc execSelectMessagesWithLimitStmt(s: SqliteStmt, 
                          contentTopic: Option[seq[ContentTopic]], 
                          pubsubTopic: Option[string],
                          cursor: Option[Index],  
                          startTime: Option[Timestamp],
                          endTime: Option[Timestamp],
                          onRowCallback: DataProc): DatabaseResult[void] =
  let s = RawStmtPtr(s)
  
  # Bind params
  var paramIndex = 1
  if contentTopic.isSome():
    for topic in contentTopic.get():
      let topicBlob = toBytes(topic)
      checkErr bindParam(s, paramIndex, topicBlob)
      paramIndex += 1

  if cursor.isSome():  # cursor = senderTimestamp, id, pubsubTopic
    let senderTimestamp = cursor.get().senderTime
    checkErr bindParam(s, paramIndex, senderTimestamp)
    paramIndex += 1

    let id = @(cursor.get().digest.data)
    checkErr bindParam(s, paramIndex, id)
    paramIndex += 1

    let pubsubTopic = toBytes(cursor.get().pubsubTopic)
    checkErr bindParam(s, paramIndex, pubsubTopic)
    paramIndex += 1

  if pubsubTopic.isSome():
    let pubsubTopic = toBytes(pubsubTopic.get())
    checkErr bindParam(s, paramIndex, pubsubTopic)
    paramIndex += 1

  if startTime.isSome():
    let time = startTime.get()
    checkErr bindParam(s, paramIndex, time)
    paramIndex += 1

  if endTime.isSome():
    let time = endTime.get()
    checkErr bindParam(s, paramIndex, time)
    paramIndex += 1


  try:
    while true:
      let v = sqlite3_step(s)
      case v
      of SQLITE_ROW:
        onRowCallback(s)
      of SQLITE_DONE:
        return ok()
      else:
        return err($sqlite3_errstr(v))
  finally:
    # release implicit transaction
    discard sqlite3_reset(s) # same return information as step
    discard sqlite3_clear_bindings(s) # no errors possible

proc selectMessagesByHistoryQueryWithLimit*(db: SqliteDatabase, 
                                            contentTopic: Option[seq[ContentTopic]], 
                                            pubsubTopic: Option[string],
                                            cursor: Option[Index],  
                                            startTime: Option[Timestamp],
                                            endTime: Option[Timestamp],
                                            limit: uint64, 
                                            ascending: bool): DatabaseResult[seq[(WakuMessage, Timestamp, string)]] =
  
   
  var messages: seq[(WakuMessage, Timestamp, string)] = @[]
  proc queryRowCallback(s: ptr sqlite3_stmt) =
    let 
      receiverTimestamp = queryRowReceiverTimestampCallback(s, receiverTimestampCol=0)
      message = queryRowWakuMessageCallback(s, contentTopicCol=1, payloadCol=2, versionCol=4, senderTimestampCol=5)
      pubsubTopic = queryRowPubsubTopicCallback(s, pubsubTopicCol=3)

    messages.add((message, receiverTimestamp, pubsubTopic))

  let query = block:
    let
      contentTopicClause = contentTopicWhereClause(contentTopic)
      cursorClause = cursorWhereClause(cursor, ascending)
      pubsubClause = pubsubWhereClause(pubsubTopic)
      timeRangeClause = timeRangeWhereClause(startTime, endTime)
    let where = whereClause(contentTopicClause, cursorClause, pubsubClause, timeRangeClause)
    selectMessagesWithLimitQuery(DbTable, where, limit, ascending)

  let dbStmt = ?db.prepareSelectMessagesWithlimitStmt(query)
  ?dbStmt.execSelectMessagesWithLimitStmt(
    contentTopic,
    pubsubTopic,
    cursor,
    startTime,
    endTime,
    queryRowCallback
  )
  dbStmt.dispose()

  ok(messages)
