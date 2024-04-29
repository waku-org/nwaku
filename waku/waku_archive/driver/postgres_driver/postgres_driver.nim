when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[nre, options, sequtils, strutils, strformat, times],
  stew/[results, byteutils, arrayops],
  db_postgres,
  postgres,
  chronos,
  chronicles
import
  ../../../common/error_handling,
  ../../../waku_core,
  ../../common,
  ../../driver,
  ../../../common/databases/db_postgres as waku_postgres,
  ./postgres_healthcheck,
  ./partitions_manager

type PostgresDriver* = ref object of ArchiveDriver
  ## Establish a separate pools for read/write operations
  writeConnPool: PgAsyncPool
  readConnPool: PgAsyncPool

  ## Partition container
  partitionMngr: PartitionManager
  futLoopPartitionFactory: Future[void]

const InsertRowStmtName = "InsertRow"
const InsertRowStmtDefinition = # TODO: get the sql queries from a file
  """INSERT INTO messages (id, messageHash, storedAt, contentTopic, payload, pubsubTopic,
  version, timestamp) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT DO NOTHING;"""

const SelectNoCursorAscStmtName = "SelectWithoutCursorAsc"
const SelectNoCursorAscStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          messageHash IN ($2) AND
          pubsubTopic = $3 AND
          storedAt >= $4 AND
          storedAt <= $5
    ORDER BY storedAt ASC, messageHash ASC LIMIT $6;"""

const SelectNoCursorDescStmtName = "SelectWithoutCursorDesc"
const SelectNoCursorDescStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          messageHash IN ($2) AND
          pubsubTopic = $3 AND
          storedAt >= $4 AND
          storedAt <= $5
    ORDER BY storedAt DESC, messageHash DESC LIMIT $6;"""

const SelectWithCursorDescStmtName = "SelectWithCursorDesc"
const SelectWithCursorDescStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          messageHash IN ($2) AND
          pubsubTopic = $3 AND
          (storedAt, messageHash) < ($4,$5) AND
          storedAt >= $6 AND
          storedAt <= $7
    ORDER BY storedAt DESC, messageHash DESC LIMIT $8;"""

const SelectWithCursorAscStmtName = "SelectWithCursorAsc"
const SelectWithCursorAscStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          messageHash IN ($2) AND
          pubsubTopic = $3 AND
          (storedAt, messageHash) > ($4,$5) AND
          storedAt >= $6 AND
          storedAt <= $7
    ORDER BY storedAt ASC, messageHash ASC LIMIT $8;"""

const SelectNoCursorV2AscStmtName = "SelectWithoutCursorV2Asc"
const SelectNoCursorV2AscStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          storedAt >= $3 AND
          storedAt <= $4
    ORDER BY storedAt ASC LIMIT $5;"""

const SelectNoCursorV2DescStmtName = "SelectWithoutCursorV2Desc"
const SelectNoCursorV2DescStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          storedAt >= $3 AND
          storedAt <= $4
    ORDER BY storedAt DESC LIMIT $5;"""

const SelectWithCursorV2DescStmtName = "SelectWithCursorV2Desc"
const SelectWithCursorV2DescStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          (storedAt, id) < ($3,$4) AND
          storedAt >= $5 AND
          storedAt <= $6
    ORDER BY storedAt DESC LIMIT $7;"""

const SelectWithCursorV2AscStmtName = "SelectWithCursorV2Asc"
const SelectWithCursorV2AscStmtDef =
  """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages
    WHERE contentTopic IN ($1) AND
          pubsubTopic = $2 AND
          (storedAt, id) > ($3,$4) AND
          storedAt >= $5 AND
          storedAt <= $6
    ORDER BY storedAt ASC LIMIT $7;"""

const DefaultMaxNumConns = 50

proc new*(
    T: type PostgresDriver,
    dbUrl: string,
    maxConnections = DefaultMaxNumConns,
    onFatalErrorAction: OnFatalErrorHandler = nil,
): ArchiveDriverResult[T] =
  ## Very simplistic split of max connections
  let maxNumConnOnEachPool = int(maxConnections / 2)

  let readConnPool = PgAsyncPool.new(dbUrl, maxNumConnOnEachPool).valueOr:
    return err("error creating read conn pool PgAsyncPool")

  let writeConnPool = PgAsyncPool.new(dbUrl, maxNumConnOnEachPool).valueOr:
    return err("error creating write conn pool PgAsyncPool")

  if not isNil(onFatalErrorAction):
    asyncSpawn checkConnectivity(readConnPool, onFatalErrorAction)

  if not isNil(onFatalErrorAction):
    asyncSpawn checkConnectivity(writeConnPool, onFatalErrorAction)

  let driver = PostgresDriver(
    writeConnPool: writeConnPool,
    readConnPool: readConnPool,
    partitionMngr: PartitionManager.new(),
  )
  return ok(driver)

proc reset*(s: PostgresDriver): Future[ArchiveDriverResult[void]] {.async.} =
  ## Clear the database partitions
  let targetSize = 0
  let forceRemoval = true
  let ret = await s.decreaseDatabaseSize(targetSize, forceRemoval)
  return ret

proc rowCallbackImpl(
    pqResult: ptr PGresult,
    outRows: var seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp, WakuMessageHash)],
) =
  ## Proc aimed to contain the logic of the callback passed to the `psasyncpool`.
  ## That callback is used in "SELECT" queries.
  ##
  ## pqResult - contains the query results
  ## outRows - seq of Store-rows. This is populated from the info contained in pqResult

  let numFields = pqResult.pqnfields()
  if numFields != 8:
    error "Wrong number of fields"
    return

  for iRow in 0 ..< pqResult.pqNtuples():
    var wakuMessage: WakuMessage
    var timestamp: Timestamp
    var version: uint
    var pubSubTopic: string
    var contentTopic: string
    var storedAt: int64
    var digest: string
    var payload: string
    var hashHex: string
    var msgHash: WakuMessageHash

    try:
      storedAt = parseInt($(pqgetvalue(pqResult, iRow, 0)))
      contentTopic = $(pqgetvalue(pqResult, iRow, 1))
      payload = parseHexStr($(pqgetvalue(pqResult, iRow, 2)))
      pubSubTopic = $(pqgetvalue(pqResult, iRow, 3))
      version = parseUInt($(pqgetvalue(pqResult, iRow, 4)))
      timestamp = parseInt($(pqgetvalue(pqResult, iRow, 5)))
      digest = parseHexStr($(pqgetvalue(pqResult, iRow, 6)))
      hashHex = parseHexStr($(pqgetvalue(pqResult, iRow, 7)))
      msgHash = fromBytes(hashHex.toOpenArrayByte(0, 31))
    except ValueError:
      error "could not parse correctly", error = getCurrentExceptionMsg()

    wakuMessage.timestamp = timestamp
    wakuMessage.version = uint32(version)
    wakuMessage.contentTopic = contentTopic
    wakuMessage.payload = @(payload.toOpenArrayByte(0, payload.high))

    outRows.add(
      (
        pubSubTopic,
        wakuMessage,
        @(digest.toOpenArrayByte(0, digest.high)),
        storedAt,
        msgHash,
      )
    )

method put*(
    s: PostgresDriver,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
    digest: MessageDigest,
    messageHash: WakuMessageHash,
    receivedTime: Timestamp,
): Future[ArchiveDriverResult[void]] {.async.} =
  let digest = toHex(digest.data)
  let messageHash = toHex(messageHash)
  let rxTime = $receivedTime
  let contentTopic = message.contentTopic
  let payload = toHex(message.payload)
  let version = $message.version
  let timestamp = $message.timestamp

  debug "put PostgresDriver", timestamp = timestamp

  return await s.writeConnPool.runStmt(
    InsertRowStmtName,
    InsertRowStmtDefinition,
    @[
      digest, messageHash, rxTime, contentTopic, payload, pubsubTopic, version,
      timestamp,
    ],
    @[
      int32(digest.len),
      int32(messageHash.len),
      int32(rxTime.len),
      int32(contentTopic.len),
      int32(payload.len),
      int32(pubsubTopic.len),
      int32(version.len),
      int32(timestamp.len),
    ],
    @[int32(0), int32(0), int32(0), int32(0), int32(0), int32(0), int32(0), int32(0)],
  )

method getAllMessages*(
    s: PostgresDriver
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## Retrieve all messages from the store.

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp, WakuMessageHash)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  (
    await s.readConnPool.pgQuery(
      """SELECT storedAt, contentTopic,
                                       payload, pubsubTopic, version, timestamp,
                                       id, messageHash FROM messages ORDER BY storedAt ASC""",
      newSeq[string](0),
      rowCallback,
    )
  ).isOkOr:
    return err("failed in query: " & $error)

  return ok(rows)

proc getPartitionsList(
    s: PostgresDriver
): Future[ArchiveDriverResult[seq[string]]] {.async.} =
  ## Retrieves the seq of partition table names.
  ## e.g: @["messages_1708534333_1708534393", "messages_1708534273_1708534333"]

  var partitions: seq[string]
  proc rowCallback(pqResult: ptr PGresult) =
    for iRow in 0 ..< pqResult.pqNtuples():
      let partitionName = $(pqgetvalue(pqResult, iRow, 0))
      partitions.add(partitionName)

  (
    await s.readConnPool.pgQuery(
      """
                      SELECT child.relname       AS partition_name
                          FROM pg_inherits
                          JOIN pg_class parent            ON pg_inherits.inhparent = parent.oid
                          JOIN pg_class child             ON pg_inherits.inhrelid   = child.oid
                          JOIN pg_namespace nmsp_parent   ON nmsp_parent.oid  = parent.relnamespace
                          JOIN pg_namespace nmsp_child    ON nmsp_child.oid   = child.relnamespace
                          WHERE parent.relname='messages'
                          ORDER BY partition_name ASC
                          """,
      newSeq[string](0),
      rowCallback,
    )
  ).isOkOr:
    return err("getPartitionsList failed in query: " & $error)

  return ok(partitions)

proc getMessagesArbitraryQuery(
    s: PostgresDriver,
    contentTopic: seq[ContentTopic] = @[],
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    hexHashes: seq[string] = @[],
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## This proc allows to handle atypical queries. We don't use prepared statements for those.

  var query =
    """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages"""
  var statements: seq[string]
  var args: seq[string]

  if contentTopic.len > 0:
    let cstmt = "contentTopic IN (" & "?".repeat(contentTopic.len).join(",") & ")"
    statements.add(cstmt)
    for t in contentTopic:
      args.add(t)

  if hexHashes.len > 0:
    let cstmt = "messageHash IN (" & "?".repeat(hexHashes.len).join(",") & ")"
    statements.add(cstmt)
    for t in hexHashes:
      args.add(t)

  if pubsubTopic.isSome():
    statements.add("pubsubTopic = ?")
    args.add(pubsubTopic.get())

  if cursor.isSome():
    let comp = if ascendingOrder: ">" else: "<"
    statements.add("(storedAt, messageHash) " & comp & " (?,?)")
    args.add($cursor.get().storeTime)
    args.add(toHex(cursor.get().hash))

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

  query &= " ORDER BY storedAt " & direction & ", messageHash " & direction

  query &= " LIMIT ?"
  args.add($maxPageSize)

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp, WakuMessageHash)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  (await s.readConnPool.pgQuery(query, args, rowCallback)).isOkOr:
    return err("failed to run query: " & $error)

  return ok(rows)

proc getMessagesV2ArbitraryQuery(
    s: PostgresDriver,
    contentTopic: seq[ContentTopic] = @[],
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async, deprecated.} =
  ## This proc allows to handle atypical queries. We don't use prepared statements for those.

  var query =
    """SELECT storedAt, contentTopic, payload, pubsubTopic, version, timestamp, id, messageHash FROM messages"""
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

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp, WakuMessageHash)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  (await s.readConnPool.pgQuery(query, args, rowCallback)).isOkOr:
    return err("failed to run query: " & $error)

  return ok(rows)

proc getMessagesPreparedStmt(
    s: PostgresDriver,
    contentTopic: string,
    pubsubTopic: PubsubTopic,
    cursor = none(ArchiveCursor),
    startTime: Timestamp,
    endTime: Timestamp,
    hashes: string,
    maxPageSize = DefaultPageSize,
    ascOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## This proc aims to run the most typical queries in a more performant way, i.e. by means of
  ## prepared statements.
  ##
  ## contentTopic - string with list of conten topics. e.g: "'ctopic1','ctopic2','ctopic3'"

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp, WakuMessageHash)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  let startTimeStr = $startTime
  let endTimeStr = $endTime
  let limit = $maxPageSize

  if cursor.isSome():
    var stmtName =
      if ascOrder: SelectWithCursorAscStmtName else: SelectWithCursorDescStmtName
    var stmtDef =
      if ascOrder: SelectWithCursorAscStmtDef else: SelectWithCursorDescStmtDef

    let hash = toHex(cursor.get().hash)
    let storeTime = $cursor.get().storeTime

    (
      await s.readConnPool.runStmt(
        stmtName,
        stmtDef,
        @[
          contentTopic, hashes, pubsubTopic, storeTime, hash, startTimeStr, endTimeStr,
          limit,
        ],
        @[
          int32(contentTopic.len),
          int32(pubsubTopic.len),
          int32(storeTime.len),
          int32(hash.len),
          int32(startTimeStr.len),
          int32(endTimeStr.len),
          int32(limit.len),
        ],
        @[int32(0), int32(0), int32(0), int32(0), int32(0), int32(0), int32(0)],
        rowCallback,
      )
    ).isOkOr:
      return err("failed to run query with cursor: " & $error)
  else:
    var stmtName =
      if ascOrder: SelectNoCursorAscStmtName else: SelectNoCursorDescStmtName
    var stmtDef = if ascOrder: SelectNoCursorAscStmtDef else: SelectNoCursorDescStmtDef

    (
      await s.readConnPool.runStmt(
        stmtName,
        stmtDef,
        @[contentTopic, hashes, pubsubTopic, startTimeStr, endTimeStr, limit],
        @[
          int32(contentTopic.len),
          int32(pubsubTopic.len),
          int32(startTimeStr.len),
          int32(endTimeStr.len),
          int32(limit.len),
        ],
        @[int32(0), int32(0), int32(0), int32(0), int32(0)],
        rowCallback,
      )
    ).isOkOr:
      return err("failed to run query without cursor: " & $error)

  return ok(rows)

proc getMessagesV2PreparedStmt(
    s: PostgresDriver,
    contentTopic: string,
    pubsubTopic: PubsubTopic,
    cursor = none(ArchiveCursor),
    startTime: Timestamp,
    endTime: Timestamp,
    maxPageSize = DefaultPageSize,
    ascOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async, deprecated.} =
  ## This proc aims to run the most typical queries in a more performant way, i.e. by means of
  ## prepared statements.
  ##
  ## contentTopic - string with list of conten topics. e.g: "'ctopic1','ctopic2','ctopic3'"

  var rows: seq[(PubsubTopic, WakuMessage, seq[byte], Timestamp, WakuMessageHash)]
  proc rowCallback(pqResult: ptr PGresult) =
    rowCallbackImpl(pqResult, rows)

  let startTimeStr = $startTime
  let endTimeStr = $endTime
  let limit = $maxPageSize

  if cursor.isSome():
    var stmtName =
      if ascOrder: SelectWithCursorV2AscStmtName else: SelectWithCursorV2DescStmtName
    var stmtDef =
      if ascOrder: SelectWithCursorV2AscStmtDef else: SelectWithCursorV2DescStmtDef

    let digest = toHex(cursor.get().digest.data)
    let storeTime = $cursor.get().storeTime

    (
      await s.readConnPool.runStmt(
        stmtName,
        stmtDef,
        @[contentTopic, pubsubTopic, storeTime, digest, startTimeStr, endTimeStr, limit],
        @[
          int32(contentTopic.len),
          int32(pubsubTopic.len),
          int32(storeTime.len),
          int32(digest.len),
          int32(startTimeStr.len),
          int32(endTimeStr.len),
          int32(limit.len),
        ],
        @[int32(0), int32(0), int32(0), int32(0), int32(0), int32(0), int32(0)],
        rowCallback,
      )
    ).isOkOr:
      return err("failed to run query with cursor: " & $error)
  else:
    var stmtName =
      if ascOrder: SelectNoCursorV2AscStmtName else: SelectNoCursorV2DescStmtName
    var stmtDef =
      if ascOrder: SelectNoCursorV2AscStmtDef else: SelectNoCursorV2DescStmtDef

    (
      await s.readConnPool.runStmt(
        stmtName,
        stmtDef,
        @[contentTopic, pubsubTopic, startTimeStr, endTimeStr, limit],
        @[
          int32(contentTopic.len),
          int32(pubsubTopic.len),
          int32(startTimeStr.len),
          int32(endTimeStr.len),
          int32(limit.len),
        ],
        @[int32(0), int32(0), int32(0), int32(0), int32(0)],
        rowCallback,
      )
    ).isOkOr:
      return err("failed to run query without cursor: " & $error)

  return ok(rows)

method getMessages*(
    s: PostgresDriver,
    includeData = false,
    contentTopicSeq = newSeq[ContentTopic](0),
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    hashes = newSeq[WakuMessageHash](0),
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  let hexHashes = hashes.mapIt(toHex(it))

  if contentTopicSeq.len == 1 and hexHashes.len == 1 and pubsubTopic.isSome() and
      startTime.isSome() and endTime.isSome():
    ## Considered the most common query. Therefore, we use prepared statements to optimize it.
    return await s.getMessagesPreparedStmt(
      contentTopicSeq.join(","),
      PubsubTopic(pubsubTopic.get()),
      cursor,
      startTime.get(),
      endTime.get(),
      hexHashes.join(","),
      maxPageSize,
      ascendingOrder,
    )
  else:
    ## We will run atypical query. In this case we don't use prepared statemets
    return await s.getMessagesArbitraryQuery(
      contentTopicSeq, pubsubTopic, cursor, startTime, endTime, hexHashes, maxPageSize,
      ascendingOrder,
    )

method getMessagesV2*(
    s: PostgresDriver,
    contentTopicSeq = newSeq[ContentTopic](0),
    pubsubTopic = none(PubsubTopic),
    cursor = none(ArchiveCursor),
    startTime = none(Timestamp),
    endTime = none(Timestamp),
    maxPageSize = DefaultPageSize,
    ascendingOrder = true,
): Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async, deprecated.} =
  if contentTopicSeq.len == 1 and pubsubTopic.isSome() and startTime.isSome() and
      endTime.isSome():
    ## Considered the most common query. Therefore, we use prepared statements to optimize it.
    return await s.getMessagesV2PreparedStmt(
      contentTopicSeq.join(","),
      PubsubTopic(pubsubTopic.get()),
      cursor,
      startTime.get(),
      endTime.get(),
      maxPageSize,
      ascendingOrder,
    )
  else:
    ## We will run atypical query. In this case we don't use prepared statemets
    return await s.getMessagesV2ArbitraryQuery(
      contentTopicSeq, pubsubTopic, cursor, startTime, endTime, maxPageSize,
      ascendingOrder,
    )

proc getStr(
    s: PostgresDriver, query: string
): Future[ArchiveDriverResult[string]] {.async.} =
  # Performs a query that is expected to return a single string

  var ret: string
  proc rowCallback(pqResult: ptr PGresult) =
    if pqResult.pqnfields() != 1:
      error "Wrong number of fields in getStr"
      return

    if pqResult.pqNtuples() != 1:
      error "Wrong number of rows in getStr"
      return

    ret = $(pqgetvalue(pqResult, 0, 0))

  (await s.readConnPool.pgQuery(query, newSeq[string](0), rowCallback)).isOkOr:
    return err("failed in getRow: " & $error)

  return ok(ret)

proc getInt(
    s: PostgresDriver, query: string
): Future[ArchiveDriverResult[int64]] {.async.} =
  # Performs a query that is expected to return a single numeric value (int64)

  var retInt = 0'i64
  let str = (await s.getStr(query)).valueOr:
    return err("could not get str in getInt: " & $error)

  try:
    retInt = parseInt(str)
  except ValueError:
    return err("exception in getInt, parseInt: " & getCurrentExceptionMsg())

  return ok(retInt)

method getDatabaseSize*(
    s: PostgresDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  let intRes = (await s.getInt("SELECT pg_database_size(current_database())")).valueOr:
    return err("error in getDatabaseSize: " & error)

  let databaseSize: int64 = int64(intRes)
  return ok(databaseSize)

method getMessagesCount*(
    s: PostgresDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  let intRes = await s.getInt("SELECT COUNT(1) FROM messages")
  if intRes.isErr():
    return err("error in getMessagesCount: " & intRes.error)

  return ok(intRes.get())

method getOldestMessageTimestamp*(
    s: PostgresDriver
): Future[ArchiveDriverResult[Timestamp]] {.async.} =
  let intRes = await s.getInt("SELECT MIN(storedAt) FROM messages")
  if intRes.isErr():
    return err("error in getOldestMessageTimestamp: " & intRes.error)

  return ok(Timestamp(intRes.get()))

method getNewestMessageTimestamp*(
    s: PostgresDriver
): Future[ArchiveDriverResult[Timestamp]] {.async.} =
  let intRes = await s.getInt("SELECT MAX(storedAt) FROM messages")
  if intRes.isErr():
    return err("error in getNewestMessageTimestamp: " & intRes.error)

  return ok(Timestamp(intRes.get()))

method deleteMessagesOlderThanTimestamp*(
    s: PostgresDriver, ts: Timestamp
): Future[ArchiveDriverResult[void]] {.async.} =
  let execRes =
    await s.writeConnPool.pgQuery("DELETE FROM messages WHERE storedAt < " & $ts)
  if execRes.isErr():
    return err("error in deleteMessagesOlderThanTimestamp: " & execRes.error)

  return ok()

method deleteOldestMessagesNotWithinLimit*(
    s: PostgresDriver, limit: int
): Future[ArchiveDriverResult[void]] {.async.} =
  let execRes = await s.writeConnPool.pgQuery(
    """DELETE FROM messages WHERE id NOT IN
                          (
                        SELECT id FROM messages ORDER BY storedAt DESC LIMIT ?
                          );""",
    @[$limit],
  )
  if execRes.isErr():
    return err("error in deleteOldestMessagesNotWithinLimit: " & execRes.error)

  return ok()

method close*(s: PostgresDriver): Future[ArchiveDriverResult[void]] {.async.} =
  ## Cancel the partition factory loop
  s.futLoopPartitionFactory.cancel()

  ## Close the database connection
  let writeCloseRes = await s.writeConnPool.close()
  let readCloseRes = await s.readConnPool.close()

  writeCloseRes.isOkOr:
    return err("error closing write pool: " & $error)

  readCloseRes.isOkOr:
    return err("error closing read pool: " & $error)

  return ok()

proc sleep*(
    s: PostgresDriver, seconds: int
): Future[ArchiveDriverResult[void]] {.async.} =
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

proc performWriteQuery*(
    s: PostgresDriver, query: string
): Future[ArchiveDriverResult[void]] {.async.} =
  ## Performs a query that somehow changes the state of the database

  (await s.writeConnPool.pgQuery(query)).isOkOr:
    return err("error in performWriteQuery: " & $error)

  return ok()

proc addPartition(
    self: PostgresDriver, startTime: Timestamp, duration: timer.Duration
): Future[ArchiveDriverResult[void]] {.async.} =
  ## Creates a partition table that will store the messages that fall in the range
  ## `startTime` <= storedAt < `startTime + duration`.
  ## `startTime` is measured in seconds since epoch

  let beginning = startTime
  let `end` = (startTime + duration.seconds)

  let fromInSec: string = $beginning
  let untilInSec: string = $`end`

  let fromInNanoSec: string = fromInSec & "000000000"
  let untilInNanoSec: string = untilInSec & "000000000"

  let partitionName = "messages_" & fromInSec & "_" & untilInSec

  let createPartitionQuery =
    "CREATE TABLE IF NOT EXISTS " & partitionName & " PARTITION OF " &
    "messages FOR VALUES FROM ('" & fromInNanoSec & "') TO ('" & untilInNanoSec & "');"

  (await self.performWriteQuery(createPartitionQuery)).isOkOr:
    return err(fmt"error adding partition [{partitionName}]: " & $error)

  debug "new partition added", query = createPartitionQuery

  self.partitionMngr.addPartitionInfo(partitionName, beginning, `end`)
  return ok()

proc initializePartitionsInfo(
    self: PostgresDriver
): Future[ArchiveDriverResult[void]] {.async.} =
  let partitionNamesRes = await self.getPartitionsList()
  if not partitionNamesRes.isOk():
    return err("Could not retrieve partitions list: " & $partitionNamesRes.error)
  else:
    let partitionNames = partitionNamesRes.get()
    for partitionName in partitionNames:
      ## partitionName contains something like 'messages_1708449815_1708449875'
      let bothTimes = partitionName.replace("messages_", "")
      let times = bothTimes.split("_")
      if times.len != 2:
        return err(fmt"loopPartitionFactory wrong partition name {partitionName}")

      var beginning: int64
      try:
        beginning = parseInt(times[0])
      except ValueError:
        return err("Could not parse beginning time: " & getCurrentExceptionMsg())

      var `end`: int64
      try:
        `end` = parseInt(times[1])
      except ValueError:
        return err("Could not parse end time: " & getCurrentExceptionMsg())

      self.partitionMngr.addPartitionInfo(partitionName, beginning, `end`)

    return ok()

const DefaultDatabasePartitionCheckTimeInterval = timer.minutes(10)
const PartitionsRangeInterval = timer.hours(1) ## Time range covered by each parition

proc loopPartitionFactory(
    self: PostgresDriver, onFatalError: OnFatalErrorHandler
) {.async.} =
  ## Loop proc that continuously checks whether we need to create a new partition.
  ## Notice that the deletion of partitions is handled by the retention policy modules.

  debug "starting loopPartitionFactory"

  if PartitionsRangeInterval < DefaultDatabasePartitionCheckTimeInterval:
    onFatalError(
      "partition factory partition range interval should be bigger than check interval"
    )

  ## First of all, let's make the 'partition_manager' aware of the current partitions
  (await self.initializePartitionsInfo()).isOkOr:
    onFatalError("issue in loopPartitionFactory: " & $error)

  while true:
    trace "Check if we need to create a new partition"

    let now = times.now().toTime().toUnix()

    if self.partitionMngr.isEmpty():
      debug "adding partition because now there aren't more partitions"
      (await self.addPartition(now, PartitionsRangeInterval)).isOkOr:
        onFatalError("error when creating a new partition from empty state: " & $error)
    else:
      let newestPartitionRes = self.partitionMngr.getNewestPartition()
      if newestPartitionRes.isErr():
        onFatalError("could not get newest partition: " & $newestPartitionRes.error)

      let newestPartition = newestPartitionRes.get()
      if newestPartition.containsMoment(now):
        debug "creating a new partition for the future"
        ## The current used partition is the last one that was created.
        ## Thus, let's create another partition for the future.

        (
          await self.addPartition(
            newestPartition.getLastMoment(), PartitionsRangeInterval
          )
        ).isOkOr:
          onFatalError("could not add the next partition for 'now': " & $error)
      elif now >= newestPartition.getLastMoment():
        debug "creating a new partition to contain current messages"
        ## There is no partition to contain the current time.
        ## This happens if the node has been stopped for quite a long time.
        ## Then, let's create the needed partition to contain 'now'.
        (await self.addPartition(now, PartitionsRangeInterval)).isOkOr:
          onFatalError("could not add the next partition: " & $error)

    await sleepAsync(DefaultDatabasePartitionCheckTimeInterval)

proc startPartitionFactory*(
    self: PostgresDriver, onFatalError: OnFatalErrorHandler
) {.async.} =
  self.futLoopPartitionFactory = self.loopPartitionFactory(onFatalError)

proc getTableSize*(
    self: PostgresDriver, tableName: string
): Future[ArchiveDriverResult[string]] {.async.} =
  ## Returns a human-readable representation of the size for the requested table.
  ## tableName - table of interest.

  let tableSize = (
    await self.getStr(
      fmt"""
                SELECT pg_size_pretty(pg_total_relation_size(C.oid)) AS "total_size"
                FROM pg_class C
                where relname = '{tableName}'"""
    )
  ).valueOr:
    return err("error in getDatabaseSize: " & error)

  return ok(tableSize)

proc removeOldestPartition(
    self: PostgresDriver, forceRemoval: bool = false, ## To allow cleanup in tests
): Future[ArchiveDriverResult[void]] {.async.} =
  ## Indirectly called from the retention policy

  let oldestPartition = self.partitionMngr.getOldestPartition().valueOr:
    return err("could not remove oldest partition: " & $error)

  if not forceRemoval:
    let now = times.now().toTime().toUnix()
    let currentPartitionRes = self.partitionMngr.getPartitionFromDateTime(now)
    if currentPartitionRes.isOk():
      ## The database contains a partition that would store current messages.

      if currentPartitionRes.get() == oldestPartition:
        debug "Skipping to remove the current partition"
        return ok()

  var partSize = ""
  let partSizeRes = await self.getTableSize(oldestPartition.getName())
  if partSizeRes.isOk():
    partSize = partSizeRes.get()

  ## In the following lines is where the partition removal happens.
  ## Detach and remove the partition concurrently to not block the parent table (messages)
  let detachPartitionQuery =
    "ALTER TABLE messages DETACH PARTITION " & oldestPartition.getName() &
    " CONCURRENTLY;"
  debug "removeOldestPartition", query = detachPartitionQuery
  (await self.performWriteQuery(detachPartitionQuery)).isOkOr:
    return err(fmt"error in {detachPartitionQuery}: " & $error)

  ## Drop the partition
  let dropPartitionQuery = "DROP TABLE " & oldestPartition.getName()
  debug "removeOldestPartition drop partition", query = dropPartitionQuery
  (await self.performWriteQuery(dropPartitionQuery)).isOkOr:
    return err(fmt"error in {dropPartitionQuery}: " & $error)

  debug "removed partition",
    partition_name = oldestPartition.getName(), partition_size = partSize
  self.partitionMngr.removeOldestPartitionName()

  return ok()

proc containsAnyPartition*(self: PostgresDriver): bool =
  return not self.partitionMngr.isEmpty()

method decreaseDatabaseSize*(
    driver: PostgresDriver, targetSizeInBytes: int64, forceRemoval: bool = false
): Future[ArchiveDriverResult[void]] {.async.} =
  var dbSize = (await driver.getDatabaseSize()).valueOr:
    return err("decreaseDatabaseSize failed to get database size: " & $error)

  ## database size in bytes
  var totalSizeOfDB: int64 = int64(dbSize)

  if totalSizeOfDB <= targetSizeInBytes:
    return ok()

  debug "start reducing database size",
    targetSize = $targetSizeInBytes, currentSize = $totalSizeOfDB

  while totalSizeOfDB > targetSizeInBytes and driver.containsAnyPartition():
    (await driver.removeOldestPartition(forceRemoval)).isOkOr:
      return err(
        "decreaseDatabaseSize inside loop failed to remove oldest partition: " & $error
      )

    dbSize = (await driver.getDatabaseSize()).valueOr:
      return
        err("decreaseDatabaseSize inside loop failed to get database size: " & $error)

    let newCurrentSize = int64(dbSize)
    if newCurrentSize == totalSizeOfDB:
      return err("the previous partition removal didn't clear database size")

    totalSizeOfDB = newCurrentSize

    debug "reducing database size",
      targetSize = $targetSizeInBytes, newCurrentSize = $totalSizeOfDB

  return ok()

method existsTable*(
    s: PostgresDriver, tableName: string
): Future[ArchiveDriverResult[bool]] {.async.} =
  let query: string =
    fmt"""
  SELECT EXISTS (
    SELECT FROM
        pg_tables
    WHERE
        tablename  = '{tableName}'
    );
    """

  var exists: string
  proc rowCallback(pqResult: ptr PGresult) =
    if pqResult.pqnfields() != 1:
      error "Wrong number of fields in existsTable"
      return

    if pqResult.pqNtuples() != 1:
      error "Wrong number of rows in existsTable"
      return

    exists = $(pqgetvalue(pqResult, 0, 0))

  (await s.readConnPool.pgQuery(query, newSeq[string](0), rowCallback)).isOkOr:
    return err("existsTable failed in getRow: " & $error)

  return ok(exists == "t")

proc getCurrentVersion*(
    s: PostgresDriver
): Future[ArchiveDriverResult[int64]] {.async.} =
  let existsVersionTable = (await s.existsTable("version")).valueOr:
    return err("error in getCurrentVersion-existsTable: " & $error)

  if not existsVersionTable:
    return ok(0)

  let res = (await s.getInt(fmt"SELECT version FROM version")).valueOr:
    return err("error in getMessagesCount: " & $error)

  return ok(res)
