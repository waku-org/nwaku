when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/strformat,
  std/nre,
  std/options,
  std/strutils,
  stew/[results,byteutils],
  db_postgres,
  chronos
import
  ../../../waku_core,
  ../../common,
  ../../driver,
  asyncpool

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

  var connPool: PgAsyncPool

  try:
    let regex = re("""^postgres:\/\/([^:]+):([^@]+)@([^:]+):(\d+)\/(.+)$""")
    let matches = find(dbUrl,regex).get.captures
    let user = matches[0]
    let password =  matches[1]
    let host = matches[2]
    let port = matches[3]
    let dbName = matches[4]
    let connectionString = fmt"user={user} host={host} port={port} dbname={dbName} password={password}"

    connPool = PgAsyncPool.new(connectionString, maxConnections)

  except KeyError,InvalidUnicodeError, RegexInternalError, ValueError, StudyError, SyntaxError:
    return err("could not parse postgres string")

  return ok(PostgresDriver(connPool: connPool))

proc createMessageTable(s: PostgresDriver):
                        Future[ArchiveDriverResult[void]] {.async.}  =

  let execRes = await s.connPool.exec(createTableQuery(), newSeq[string](0))
  if execRes.isErr():
    return err("error in createMessageTable: " & execRes.error)

  return ok()

proc deleteMessageTable*(s: PostgresDriver):
                         Future[ArchiveDriverResult[void]] {.async.} =

  let ret = await s.connPool.exec(dropTableQuery(), newSeq[string](0))
  return ret

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
    args.add($cursor.get().digest.data)

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

method getMessagesCount*(s: PostgresDriver):
                         Future[ArchiveDriverResult[int64]] {.async.} =

  let rowsRes = await s.connPool.query("SELECT COUNT(1) FROM messages")
  if rowsRes.isErr():
    return err("failed to get messages count: " & rowsRes.error)

  let rows = rowsRes.get()
  if rows.len == 0:
    return err("failed to get messages count: rows.len == 0")

  let rowFields = rows[0]
  if rowFields.len == 0:
    return err("failed to get messages count: rowFields.len == 0")

  let count = parseInt(rowFields[0])
  return ok(count)

method getOldestMessageTimestamp*(s: PostgresDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return err("not implemented")

method getNewestMessageTimestamp*(s: PostgresDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return err("not implemented")

method deleteMessagesOlderThanTimestamp*(s: PostgresDriver,
                                         ts: Timestamp):
                                         Future[ArchiveDriverResult[void]] {.async.} =
  return err("not implemented")

method deleteOldestMessagesNotWithinLimit*(s: PostgresDriver,
                                           limit: int):
                                           Future[ArchiveDriverResult[void]] {.async.} =
  return err("not implemented")

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
