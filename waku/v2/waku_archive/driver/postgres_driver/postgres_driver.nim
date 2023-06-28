when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[strformat,nre,options,strutils],
  stew/[results,byteutils],
  db_postgres,
  chronos
import
  ../../../waku_core,
  ../../common,
  ../../driver,
  ../../../../common/databases/db_postgres as waku_postgres

export postgres_driver

type PostgresDriver* = ref object of ArchiveDriver
  connPool: PgAsyncPool

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
  " storedAt BIGINT NOT NULL," &
  " CONSTRAINT messageIndex PRIMARY KEY (storedAt, id, pubsubTopic)" &
  ");"

proc insertRow(): string =
  # TODO: get the sql queries from a file
 """INSERT INTO messages (id, storedAt, contentTopic, payload, pubsubTopic,
  version, timestamp) VALUES ($1, $2, $3, $4, $5, $6, $7);"""

const DefaultMaxConnections = 5

proc new*(T: type PostgresDriver,
          dbUrl: string,
          maxConnections: int = DefaultMaxConnections):
          ArchiveDriverResult[T] =

  let connPoolRes = PgAsyncPool.new(dbUrl, maxConnections)
  if connPoolRes.isErr():
    return err("error creating PgAsyncPool: " & connPoolRes.error)

  return ok(PostgresDriver(connPool: connPoolRes.get()))

proc createMessageTable*(s: PostgresDriver):
                         Future[ArchiveDriverResult[void]] {.async.}  =

  let execRes = await s.connPool.exec(createTableQuery())
  if execRes.isErr():
    return err("error in createMessageTable: " & execRes.error)

  return ok()

proc deleteMessageTable*(s: PostgresDriver):
                         Future[ArchiveDriverResult[void]] {.async.} =

  let execRes = await s.connPool.exec(dropTableQuery())
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

method put*(s: PostgresDriver,
            pubsubTopic: PubsubTopic,
            message: WakuMessage,
            digest: MessageDigest,
            receivedTime: Timestamp):
            Future[ArchiveDriverResult[void]] {.async.} =

  let ret = await s.connPool.runStmt(insertRow(),
                                     @[toHex(digest.data),
                                       $receivedTime,
                                       message.contentTopic,
                                       toHex(message.payload),
                                       pubsubTopic,
                                       $message.version,
                                       $message.timestamp])
  return ret

proc toArchiveRow(r: Row): ArchiveDriverResult[ArchiveRow] =
  # Converts a postgres row into an ArchiveRow

  var wakuMessage: WakuMessage
  var timestamp: Timestamp
  var version: uint
  var pubSubTopic: string
  var contentTopic: string
  var storedAt: int64
  var digest: string
  var payload: string

  try:
    storedAt = parseInt(r[0])
    contentTopic = r[1]
    payload = parseHexStr(r[2])
    pubSubTopic = r[3]
    version = parseUInt(r[4])
    timestamp = parseInt(r[5])
    digest = parseHexStr(r[6])
  except ValueError:
    return err("could not parse timestamp")

  wakuMessage.timestamp = timestamp
  wakuMessage.version = uint32(version)
  wakuMessage.contentTopic = contentTopic
  wakuMessage.payload = @(payload.toOpenArrayByte(0, payload.high))

  return ok((pubSubTopic,
             wakuMessage,
             @(digest.toOpenArrayByte(0, digest.high)),
             storedAt))

method getAllMessages*(s: PostgresDriver):
                       Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  ## Retrieve all messages from the store.

  let rowsRes = await s.connPool.query("""SELECT storedAt, contentTopic,
                                       payload, pubsubTopic, version, timestamp,
                                       id FROM messages ORDER BY storedAt ASC""",
                                       newSeq[string](0))

  if rowsRes.isErr():
    return err("failed in query: " & rowsRes.error)

  var results: seq[ArchiveRow]
  for r in rowsRes.value:
    let rowRes = r.toArchiveRow()
    if rowRes.isErr():
      return err("failed to extract row")

    results.add(rowRes.get())

  return ok(results)

method getMessages*(s: PostgresDriver,
                    contentTopic: seq[ContentTopic] = @[],
                    pubsubTopic = none(PubsubTopic),
                    cursor = none(ArchiveCursor),
                    startTime = none(Timestamp),
                    endTime = none(Timestamp),
                    maxPageSize = DefaultPageSize,
                    ascendingOrder = true):
                    Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  var query = """SELECT storedAt, contentTopic, payload,
  pubsubTopic, version, timestamp, id FROM messages"""
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

  let rowsRes = await s.connPool.query(query, args)
  if rowsRes.isErr():
    return err("failed to run query: " & rowsRes.error)

  var results: seq[ArchiveRow]
  for r in rowsRes.value:
    let rowRes = r.toArchiveRow()
    if rowRes.isErr():
      return err("failed to extract row: " & rowRes.error)

    results.add(rowRes.get())

  return ok(results)

proc getInt(s: PostgresDriver,
            query: string):
            Future[ArchiveDriverResult[int64]] {.async.} =
  # Performs a query that is expected to return a single numeric value (int64)

  let rowsRes = await s.connPool.query(query)
  if rowsRes.isErr():
    return err("failed in getRow: " & rowsRes.error)

  let rows = rowsRes.get()
  if rows.len != 1:
    return err("failed in getRow. Expected one row but got " & $rows.len)

  let fields = rows[0]
  if fields.len != 1:
    return err("failed in getRow: Expected one field but got " & $fields.len)

  var retInt = 0'i64
  try:
    if fields[0] != "":
      retInt = parseInt(fields[0])
  except ValueError:
    return err("exception in getRow, parseInt: " & getCurrentExceptionMsg())

  return ok(retInt)

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

  let execRes = await s.connPool.exec(
                            "DELETE FROM messages WHERE storedAt < " & $ts)
  if execRes.isErr():
    return err("error in deleteMessagesOlderThanTimestamp: " & execRes.error)

  return ok()

method deleteOldestMessagesNotWithinLimit*(
                                 s: PostgresDriver,
                                 limit: int):
                                 Future[ArchiveDriverResult[void]] {.async.} =

  let execRes = await s.connPool.exec(
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
  let result = await s.connPool.close()
  return result

proc sleep*(s: PostgresDriver, seconds: int):
            Future[ArchiveDriverResult[void]] {.async.} =
  # This is for testing purposes only. It is aimed to test the proper
  # implementation of asynchronous requests. It merely triggers a sleep in the
  # database for the amount of seconds given as a parameter.
  try:
    let params = @[$seconds]
    let sleepRes = await s.connPool.query("SELECT pg_sleep(?)", params)
    if sleepRes.isErr():
      return err("error in postgres_driver sleep: " & sleepRes.error)
  except DbError:
    # This always raises an exception although the sleep works
    return err("exception sleeping: " & getCurrentExceptionMsg())

  return ok()
