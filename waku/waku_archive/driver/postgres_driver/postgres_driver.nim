when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[nre,options,sequtils,strutils,times],
  stew/[results,byteutils],
  db_postgres,
  postgres,
  chronos,
  chronicles
import
  ../../../waku_core,
  ../../common,
  ../../driver,
  ../../../common/databases/db_postgres as waku_postgres,
  ./postgres_healthcheck

export postgres_driver

type PostgresDriver* = ref object of ArchiveDriver
  ## Establish a separate pools for read/write operations
  writeConnPool: PgAsyncPool
  readConnPool: PgAsyncPool

proc dropTableQuery(): string =
  "DROP TABLE messages"

proc createTableQuery(): string =
  "CREATE TABLE IF NOT EXISTS messages (" &
  " pubsubTopic VARCHAR NOT NULL," &
  " contentTopic VARCHAR NOT NULL," &
  " payload VARCHAR," &
  " version INTEGER NOT NULL," &
  " timestamp BIGINT NOT NULL," &
  " id VARCHAR NOT NULL," &
  " messageHash VARCHAR NOT NULL," &
  " storedAt BIGINT NOT NULL," &
  " CONSTRAINT messageIndex PRIMARY KEY (messageHash)" &
  ");"

const InsertRowStmtName = "InsertRow"
const InsertRowStmtDefinition =
  # TODO: get the sql queries from a file
 """INSERT INTO messages (id, messageHash, storedAt, contentTopic, payload, pubsubTopic,
  version, timestamp) VALUES ($1, $2, $3, $4, $5, $6, $7, $8);"""

const SelectNoCursorAscStmtName = "SelectWithoutCursorAsc"
const SelectNoCursorAscStmtDef =
 """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          storedAt >= $3 AND
          storedAt <= $4
    ORDER BY storedAt ASC LIMIT $5;"""

const SelectNoCursorDescStmtName = "SelectWithoutCursorDesc"
const SelectNoCursorDescStmtDef =
 """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          storedAt >= $3 AND
          storedAt <= $4
    ORDER BY storedAt DESC LIMIT $5;"""

const SelectWithCursorDescStmtName = "SelectWithCursorDesc"
const SelectWithCursorDescStmtDef =
 """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          (storedAt, id) < ($3,$4) AND
          storedAt >= $5 AND
          storedAt <= $6
    ORDER BY storedAt DESC LIMIT $7;"""

const SelectWithCursorAscStmtName = "SelectWithCursorAsc"
const SelectWithCursorAscStmtDef =
 """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          (storedAt, id) > ($3,$4) AND
          storedAt >= $5 AND
          storedAt <= $6
    ORDER BY storedAt ASC LIMIT $7;"""

const DefaultMaxNumConns = 50

proc new*(T: type PostgresDriver,
          dbUrl: string,
          maxConnections = DefaultMaxNumConns,
          onErrAction: OnErrHandler = nil):
          ArchiveDriverResult[T] =

  ## Very simplistic split of max connections
  let maxNumConnOnEachPool = int(maxConnections / 2)

  let readConnPool = PgAsyncPool.new(dbUrl, maxNumConnOnEachPool).valueOr:
    return err("error creating read conn pool PgAsyncPool")

  let writeConnPool = PgAsyncPool.new(dbUrl, maxNumConnOnEachPool).valueOr:
    return err("error creating write conn pool PgAsyncPool")

  if not isNil(onErrAction):
    asyncSpawn checkConnectivity(readConnPool, onErrAction)

  if not isNil(onErrAction):
    asyncSpawn checkConnectivity(writeConnPool, onErrAction)

  return ok(PostgresDriver(writeConnPool: writeConnPool,
                           readConnPool: readConnPool))

proc createMessageTable*(s: PostgresDriver):
                         Future[ArchiveDriverResult[void]] {.async.}  =

  let execRes = await s.writeConnPool.pgQuery(createTableQuery())
  if execRes.isErr():
    return err("error in createMessageTable: " & execRes.error)

  return ok()

proc deleteMessageTable*(s: PostgresDriver):
                         Future[ArchiveDriverResult[void]] {.async.} =

  let execRes = await s.writeConnPool.pgQuery(dropTableQuery())
  if execRes.isErr():
    return err("error in deleteMessageTable: " & execRes.error)

  return ok()

proc init*(s: PostgresDriver): Future[ArchiveDriverResult[void]] {.async.} =

  let createMsgRes = await s.createMessageTable()
  if createMsgRes.isErr():
    return err("createMsgRes.isErr in init: " & createMsgRes.error)

  return ok()

proc reset*(s: PostgresDriver): Future[ArchiveDriverResult[void]] {.async.} =

  let ret = await s.deleteMessageTable()
  return ret

proc rowCallbackImpl(pqResult: ptr PGresult,
                     outRows: var seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp)]) =
  ## Proc aimed to contain the logic of the callback passed to the `psasyncpool`.
  ## That callback is used in "SELECT" queries.
  ##
  ## pqResult - contains the query results
  ## outRows - seq of Store-rows. This is populated from the info contained in pqResult

  let numFields = pqResult.pqnfields()
  if numFields != 7:
    error "Wrong number of fields"
    return

  for iRow in 0..<pqResult.pqNtuples():

    var wakuMessage: WakuMessage
    var timestamp: Timestamp
    var version: uint
    var pubSubTopic: string
    var contentTopic: string
    var storedAt: int64
    var digest: string
    var payload: string

    try:
      storedAt = parseInt( $(pqgetvalue(pqResult, iRow, 0)) )
      contentTopic = $(pqgetvalue(pqResult, iRow, 1))
      payload = parseHexStr( $(pqgetvalue(pqResult, iRow, 2)) )
      pubSubTopic = $(pqgetvalue(pqResult, iRow, 3))
      version = parseUInt( $(pqgetvalue(pqResult, iRow, 4)) )
      timestamp = parseInt( $(pqgetvalue(pqResult, iRow, 5)) )
      digest = parseHexStr( $(pqgetvalue(pqResult, iRow, 6)) )
    except ValueError:
      error "could not parse correctly", error = getCurrentExceptionMsg()

    wakuMessage.timestamp = timestamp
    wakuMessage.version = uint32(version)
    wakuMessage.contentTopic = contentTopic
    wakuMessage.payload = @(payload.toOpenArrayByte(0, payload.high))

    outRows.add((pubSubTopic,
                 wakuMessage,
                 @(digest.toOpenArrayByte(0, digest.high)),
                 storedAt))

method put*(s: PostgresDriver,
            pubsubTopic: PubsubTopic,
            message: WakuMessage,
            digest: MessageDigest,
            messageHash: WakuMessageHash,
            receivedTime: Timestamp):
            Future[ArchiveDriverResult[void]] {.async.} =

  let digest = toHex(digest.data)
  let messageHash = toHex(messageHash)
  let rxTime = $receivedTime
  let contentTopic = message.contentTopic
  let payload = toHex(message.payload)
  let version = $message.version
  let timestamp = $message.timestamp

  return await s.writeConnPool.runStmt(InsertRowStmtName,
                                       InsertRowStmtDefinition,
                                     @[digest,
                                       messageHash,
                                       rxTime,
                                       contentTopic,
                                       payload,
                                       pubsubTopic,
                                       version,
                                       timestamp],
                                     @[int32(digest.len),
                                       int32(messageHash.len),
                                       int32(rxTime.len),
                                       int32(contentTopic.len),
                                       int32(payload.len),
                                       int32(pubsubTopic.len),
                                       int32(version.len),
                                       int32(timestamp.len)],
                                     @[int32(0), int32(0), int32(0), int32(0),
                                       int32(0), int32(0), int32(0), int32(0)])

method getAllMessages*(s: PostgresDriver):
                       Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## Retrieve all messages from the store.

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  (await s.readConnPool.pgQuery("""SELECT storedAt, contentTopic,
                                       payload, pubsubTopic, version, timestamp,
                                       id FROM messages ORDER BY storedAt ASC""",
                                       newSeq[string](0),
                                       rowCallback
                              )).isOkOr:
    return err("failed in query: " & $error)

  return ok(rows)

proc getMessagesArbitraryQuery(s: PostgresDriver,
                    contentTopic: seq[ContentTopic] = @[],
                    pubsubTopic = none(PubsubTopic),
                    cursor = none(ArchiveCursor),
                    startTime = none(Timestamp),
                    endTime = none(Timestamp),
                    maxPageSize = DefaultPageSize,
                    ascendingOrder = true):
                    Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## This proc allows to handle atypical queries. We don't use prepared statements for those.

  var query = """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id FROM messages"""
  var statements: seq[string]
  var args: seq[string]

  if contentTopic.len > 0:
    let cstmt = "contentTopic IN (" & "?".repeat(contentTopic.len).join(",") & ")"
    statements.add(cstmt)
    for t in contentTopic:
      args.add(t)

  if pubsubTopic.isSome():
    statements.add("pubsubTopic = ?")
    args.add(pubsubTopic.get())

  if cursor.isSome():
    let comp = if ascendingOrder: ">" else: "<"
    statements.add("(storedAt, id) " & comp & " (?,?)")
    args.add($cursor.get().storeTime)
    args.add(toHex(cursor.get().digest.data))

  if startTime.isSome():
    statements.add("storedAt >= ?")
    args.add($startTime.get())

  if endTime.isSome():
    statements.add("storedAt <= ?")
    args.add($endTime.get())

  if statements.len > 0:
    query &= " WHERE " & statements.join(" AND ")

  var direction: string
  if ascendingOrder:
    direction = "ASC"
  else:
    direction = "DESC"

  query &= " ORDER BY storedAt " & direction & ", id " & direction

  query &= " LIMIT ?"
  args.add($maxPageSize)

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  (await s.readConnPool.pgQuery(query, args, rowCallback)).isOkOr:
    return err("failed to run query: " & $error)

  return ok(rows)

proc getMessagesPreparedStmt(s: PostgresDriver,
                    contentTopic: string,
                    pubsubTopic: PubsubTopic,
                    cursor = none(ArchiveCursor),
                    startTime: Timestamp,
                    endTime: Timestamp,
                    maxPageSize = DefaultPageSize,
                    ascOrder = true):
                    Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =

  ## This proc aims to run the most typical queries in a more performant way, i.e. by means of
  ## prepared statements.
  ##
  ## contentTopic - string with list of conten topics. e.g: "'ctopic1','ctopic2','ctopic3'"

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  let startTimeStr = $startTime
  let endTimeStr = $endTime
  let limit = $maxPageSize

  if cursor.isSome():
    var stmtName = if ascOrder: SelectWithCursorAscStmtName else: SelectWithCursorDescStmtName
    var stmtDef = if ascOrder: SelectWithCursorAscStmtDef else: SelectWithCursorDescStmtDef

    let digest = toHex(cursor.get().digest.data)
    let storeTime = $cursor.get().storeTime

    (await s.readConnPool.runStmt(
                                  stmtName,
                                  stmtDef,
                                 @[contentTopic,
                                   pubsubTopic,
                                   storeTime,
                                   digest,
                                   startTimeStr,
                                   endTimeStr,
                                   limit],
                                 @[int32(contentTopic.len),
                                   int32(pubsubTopic.len),
                                   int32(storeTime.len),
                                   int32(digest.len),
                                   int32(startTimeStr.len),
                                   int32(endTimeStr.len),
                                   int32(limit.len)],
                                 @[int32(0), int32(0), int32(0), int32(0),
                                   int32(0), int32(0), int32(0)],
                                  rowCallback)
    ).isOkOr:
      return err("failed to run query with cursor: " & $error)

  else:
    var stmtName = if ascOrder: SelectNoCursorAscStmtName else: SelectNoCursorDescStmtName
    var stmtDef = if ascOrder: SelectNoCursorAscStmtDef else: SelectNoCursorDescStmtDef
    (await s.readConnPool.runStmt(stmtName,
                                  stmtDef,
                                 @[contentTopic,
                                   pubsubTopic,
                                   startTimeStr,
                                   endTimeStr,
                                   limit],
                                 @[int32(contentTopic.len),
                                   int32(pubsubTopic.len),
                                   int32(startTimeStr.len),
                                   int32(endTimeStr.len),
                                   int32(limit.len)],
                                 @[int32(0), int32(0), int32(0), int32(0), int32(0)],
                                  rowCallback)
    ).isOkOr:
      return err("failed to run query without cursor: " & $error)

  return ok(rows)

method getMessages*(s: PostgresDriver,
                    contentTopicSeq: seq[ContentTopic] = @[],
                    pubsubTopic = none(PubsubTopic),
                    cursor = none(ArchiveCursor),
                    startTime = none(Timestamp),
                    endTime = none(Timestamp),
                    maxPageSize = DefaultPageSize,
                    ascendingOrder = true):
                    Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =

  if contentTopicSeq.len == 1 and
    pubsubTopic.isSome() and
    startTime.isSome() and
    endTime.isSome():

    ## Considered the most common query. Therefore, we use prepared statements to optimize it.
    return await s.getMessagesPreparedStmt(contentTopicSeq.join(","),
                                           PubsubTopic(pubsubTopic.get()),
                                           cursor,
                                           startTime.get(),
                                           endTime.get(),
                                           maxPageSize,
                                           ascendingOrder)
  else:
    ## We will run atypical query. In this case we don't use prepared statemets
    return await s.getMessagesArbitraryQuery(contentTopicSeq,
                                             pubsubTopic,
                                             cursor,
                                             startTime,
                                             endTime,
                                             maxPageSize,
                                             ascendingOrder)

proc getInt(s: PostgresDriver,
            query: string):
            Future[ArchiveDriverResult[int64]] {.async.} =
  # Performs a query that is expected to return a single numeric value (int64)

  var retInt = 0'i64
  proc rowCallback(pqResult: ptr PGresult) =
    if pqResult.pqnfields() != 1:
      error "Wrong number of fields in getInt"
      return

    if pqResult.pqNtuples() != 1:
      error "Wrong number of rows in getInt"
      return

    try:
      retInt = parseInt( $(pqgetvalue(pqResult, 0, 0)) )
    except ValueError:
      error "exception in getInt, parseInt", error = getCurrentExceptionMsg()
      return

  (await s.readConnPool.pgQuery(query, newSeq[string](0), rowCallback)).isOkOr:
    return err("failed in getRow: " & $error)

  return ok(retInt)

method getDatabaseSize*(s: PostgresDriver):
                         Future[ArchiveDriverResult[int64]] {.async.} =

  let intRes = (await s.getInt("SELECT pg_database_size(current_database())")).valueOr:
    return err("error in getDatabaseSize: " & error)

  let databaseSize: int64 = int64(intRes)
  return ok(databaseSize)

method getMessagesCount*(s: PostgresDriver):
                         Future[ArchiveDriverResult[int64]] {.async.} =

  let intRes = await s.getInt("SELECT COUNT(1) FROM messages")
  if intRes.isErr():
    return err("error in getMessagesCount: " & intRes.error)

  return ok(intRes.get())

method getOldestMessageTimestamp*(s: PostgresDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =

  let intRes = await s.getInt("SELECT MIN(storedAt) FROM messages")
  if intRes.isErr():
    return err("error in getOldestMessageTimestamp: " & intRes.error)

  return ok(Timestamp(intRes.get()))

method getNewestMessageTimestamp*(s: PostgresDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =

  let intRes = await s.getInt("SELECT MAX(storedAt) FROM messages")
  if intRes.isErr():
    return err("error in getNewestMessageTimestamp: " & intRes.error)

  return ok(Timestamp(intRes.get()))

method deleteMessagesOlderThanTimestamp*(
                                 s: PostgresDriver,
                                 ts: Timestamp):
                                 Future[ArchiveDriverResult[void]] {.async.} =

  let execRes = await s.writeConnPool.pgQuery(
                            "DELETE FROM messages WHERE storedAt < " & $ts)
  if execRes.isErr():
    return err("error in deleteMessagesOlderThanTimestamp: " & execRes.error)

  return ok()

method deleteOldestMessagesNotWithinLimit*(
                                 s: PostgresDriver,
                                 limit: int):
                                 Future[ArchiveDriverResult[void]] {.async.} =

  let execRes = await s.writeConnPool.pgQuery(
                     """DELETE FROM messages WHERE id NOT IN
                          (
                        SELECT id FROM messages ORDER BY storedAt DESC LIMIT ?
                          );""",
                     @[$limit])
  if execRes.isErr():
    return err("error in deleteOldestMessagesNotWithinLimit: " & execRes.error)

  return ok()

method close*(s: PostgresDriver):
              Future[ArchiveDriverResult[void]] {.async.} =
  ## Close the database connection
  let writeCloseRes = await s.writeConnPool.close()
  let readCloseRes = await s.readConnPool.close()

  writeCloseRes.isOkOr:
    return err("error closing write pool: " & $error)

  readCloseRes.isOkOr:
    return err("error closing read pool: " & $error)

  return ok()

proc sleep*(s: PostgresDriver, seconds: int):
            Future[ArchiveDriverResult[void]] {.async.} =
  # This is for testing purposes only. It is aimed to test the proper
  # implementation of asynchronous requests. It merely triggers a sleep in the
  # database for the amount of seconds given as a parameter.

  proc rowCallback(result: ptr PGresult) =
    ## We are not interested in any value in this case
    discard

  try:
    let params = @[$seconds]
    (await s.writeConnPool.pgQuery("SELECT pg_sleep(?)", params, rowCallback)).isOkOr:
      return err("error in postgres_driver sleep: " & $error)

  except DbError:
    # This always raises an exception although the sleep works
    return err("exception sleeping: " & getCurrentExceptionMsg())

  return ok()
