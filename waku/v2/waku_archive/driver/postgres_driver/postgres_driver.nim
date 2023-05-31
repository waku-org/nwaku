when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/db_postgres,
  std/strformat,
  std/nre,
  std/options,
  std/strutils,
  stew/[results,byteutils],
  chronos

import
  ../../../waku_core,
  ../../common,
  ../../driver

export postgres_driver

type PostgresDriver* = ref object of ArchiveDriver
  connection: DbConn
  preparedInsert: SqlPrepared

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
 """INSERT INTO messages (id, storedAt, contentTopic, payload, pubsubTopic,
  version, timestamp) VALUES ($1, $2, $3, $4, $5, $6, $7);"""

proc new*(T: type PostgresDriver, storeMessageDbUrl: string): ArchiveDriverResult[T] =
  var host: string
  var user: string
  var password: string
  var dbName: string
  var port: string
  var connectionString: string
  var dbConn: DbConn
  try:
    let regex = re("""^postgres:\/\/([^:]+):([^@]+)@([^:]+):(\d+)\/(.+)$""")
    let matches = find(storeMessageDbUrl,regex).get.captures
    user = matches[0]
    password =  matches[1]
    host = matches[2]
    port = matches[3]
    dbName = matches[4]
    connectionString = "user={user} host={host} port={port} dbname={dbName} password={password}".fmt
  except KeyError,InvalidUnicodeError, RegexInternalError, ValueError, StudyError, SyntaxError:
    return err("could not parse postgres string")

  try:
    dbConn = open("","", "", connectionString)
  except DbError:
    return err("could not connect to postgres")

  return ok(PostgresDriver(connection: dbConn))

method reset*(s: PostgresDriver): ArchiveDriverResult[void] {.base.} =
  try:
    let res = s.connection.tryExec(sql(dropTableQuery()))
    if not res:
      return err("failed to reset database")
  except DbError:
    return err("failed to reset database")

  return ok()

method init*(s: PostgresDriver): ArchiveDriverResult[void] {.base.} =
  try:
    let res = s.connection.tryExec(sql(createTableQuery()))
    if not res:
      return err("failed to initialize")
    s.preparedInsert = prepare(s.connection, "insertRow", sql(insertRow()), 7)
  except DbError:
    let
      e = getCurrentException()
      msg = getCurrentExceptionMsg()
      exceptionMessage = "failed to init driver, got exception " &
                          repr(e) & " with message " & msg
    return err(exceptionMessage)

  return ok()

method put*(s: PostgresDriver,
            pubsubTopic: PubsubTopic,
            message: WakuMessage,
            digest: MessageDigest,
            receivedTime: Timestamp):
            Future[ArchiveDriverResult[void]] {.async.} =
  try:
    let res = s.connection.tryExec(s.preparedInsert,
                                   toHex(digest.data),
                                   receivedTime,
                                   message.contentTopic,
                                   toHex(message.payload),
                                   pubsubTopic,
                                   int64(message.version),
                                   message.timestamp)
    if not res:
      return err("failed to insert into database")
  except DbError:
    return err("failed to insert into database")

  return ok()

proc extractRow(r: Row): ArchiveDriverResult[ArchiveRow] =
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
  var rows: seq[Row]
  var results: seq[ArchiveRow]
  try:
    rows = s.connection.getAllRows(sql("""SELECT storedAt, contentTopic,
                                  payload, pubsubTopic, version, timestamp,
                                  id FROM messages ORDER BY storedAt ASC"""))
  except DbError:
    return err("failed to query rows")

  for r in rows:
    let rowRes = extractRow(r)
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

  var rows: seq[Row]
  var results: seq[ArchiveRow]
  try:
    rows = s.connection.getAllRows(sql(query), args)
  except DbError:
    return err("failed to query rows")

  for r in rows:
    let rowRes = extractRow(r)
    if rowRes.isErr():
      return err("failed to extract row")

    results.add(rowRes.get())

  return ok(results)

method getMessagesCount*(s: PostgresDriver):
                         Future[ArchiveDriverResult[int64]] {.async.} =
  var count: int64
  try:
    let row = s.connection.getRow(sql("""SELECT COUNT(1) FROM messages"""))
    count = parseInt(row[0])

  except DbError:
    return err("failed to query count")
  except ValueError:
    return err("failed to parse query count result")

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
  s.connection.close()
  return ok()

proc sleep*(s: PostgresDriver, seconds: int):
            Future[ArchiveDriverResult[void]] {.async.} =
  # This is for testing purposes only. It is aimed to test the proper
  # implementation of asynchronous requests. It merely triggers a sleep in the
  # database for the amount of seconds given as a parameter.
  try:
    let params = @[$seconds]
    s.connection.exec(sql"SELECT pg_sleep(?)", params)
  except DbError:
    # This always raises an exception although the sleep works
    return err("exception sleeping: " & getCurrentExceptionMsg())

  return ok()