import
  std/[times, strutils, asyncnet, os, sequtils],
  results,
  chronos,
  metrics,
  re,
  chronicles
import ./query_metrics

include db_connector/db_postgres

type DataProc* = proc(result: ptr PGresult) {.closure, gcsafe, raises: [].}

## Connection management

proc check*(db: DbConn): Result[void, string] =
  var message: string
  try:
    message = $db.pqErrorMessage()
  except ValueError, DbError:
    return err("exception in check: " & getCurrentExceptionMsg())

  if message.len > 0:
    return err($message)

  return ok()

proc open*(connString: string): Result[DbConn, string] =
  ## Opens a new connection.
  var conn: DbConn = nil
  try:
    conn = open("", "", "", connString)
  except DbError:
    return err("exception opening new connection: " & getCurrentExceptionMsg())

  if conn.status != CONNECTION_OK:
    let checkRes = conn.check()
    if checkRes.isErr():
      return err("failed to connect to database: " & checkRes.error)

    return err("unknown reason")

  ## registering the socket fd in chronos for better wait for data
  let asyncFd = cast[asyncengine.AsyncFD](pqsocket(conn))
  asyncengine.register(asyncFd)

  return ok(conn)

proc closeDbConn*(db: DbConn) {.raises: [OSError].} =
  let fd = db.pqsocket()
  if fd != -1:
    asyncengine.unregister(cast[asyncengine.AsyncFD](fd))
  db.close()

proc `$`(self: SqlQuery): string =
  return cast[string](self)

proc sendQuery(
    db: DbConn, query: SqlQuery, args: seq[string]
): Future[Result[void, string]] {.async.} =
  ## This proc can be used directly for queries that don't retrieve values back.

  if db.status != CONNECTION_OK:
    db.check().isOkOr:
      return err("failed to connect to database: " & $error)

    return err("unknown reason")

  var wellFormedQuery = ""
  try:
    wellFormedQuery = dbFormat(query, args)
  except DbError:
    return err("exception formatting the query: " & getCurrentExceptionMsg())

  let success = db.pqsendQuery(cstring(wellFormedQuery))
  if success != 1:
    db.check().isOkOr:
      return err("failed pqsendQuery: " & $error)

    return err("failed pqsendQuery: unknown reason")

  return ok()

proc sendQueryPrepared(
    db: DbConn,
    stmtName: string,
    paramValues: openArray[string],
    paramLengths: openArray[int32],
    paramFormats: openArray[int32],
): Result[void, string] {.raises: [].} =
  ## This proc can be used directly for queries that don't retrieve values back.

  if paramValues.len != paramLengths.len or paramValues.len != paramFormats.len or
      paramLengths.len != paramFormats.len:
    let lengthsErrMsg =
      $paramValues.len & " " & $paramLengths.len & " " & $paramFormats.len
    return err("lengths discrepancies in sendQueryPrepared: " & $lengthsErrMsg)

  if db.status != CONNECTION_OK:
    db.check().isOkOr:
      return err("failed to connect to database: " & $error)

    return err("unknown reason")

  var cstrArrayParams = allocCStringArray(paramValues)
  defer:
    deallocCStringArray(cstrArrayParams)

  let nParams = cast[int32](paramValues.len)

  const ResultFormat = 0 ## 0 for text format, 1 for binary format.

  let success = db.pqsendQueryPrepared(
    stmtName,
    nParams,
    cstrArrayParams,
    unsafeAddr paramLengths[0],
    unsafeAddr paramFormats[0],
    ResultFormat,
  )
  if success != 1:
    db.check().isOkOr:
      return err("failed pqsendQueryPrepared: " & $error)

    return err("failed pqsendQueryPrepared: unknown reason")

  return ok()

proc waitQueryToFinish(
    db: DbConn, rowCallback: DataProc = nil
): Future[Result[void, string]] {.async.} =
  ## The 'rowCallback' param is != nil when the underlying query wants to retrieve results (SELECT.)
  ## For other queries, like "INSERT", 'rowCallback' should be nil.

  var dataAvailable = false
  proc onDataAvailable(udata: pointer) {.gcsafe, raises: [].} =
    dataAvailable = true

  let asyncFd = cast[asyncengine.AsyncFD](pqsocket(db))

  asyncengine.addReader2(asyncFd, onDataAvailable).isOkOr:
    return err("failed to add event reader in waitQueryToFinish: " & $error)

  while not dataAvailable:
    await sleepAsync(timer.milliseconds(1))

  ## Now retrieve the result
  while true:
    let pqResult = db.pqgetResult()

    if pqResult == nil:
      db.check().isOkOr:
        return err("error in query: " & $error)

      return ok() # reached the end of the results

    if not rowCallback.isNil():
      rowCallback(pqResult)

    pqclear(pqResult)

proc dbConnQuery*(
    db: DbConn, query: SqlQuery, args: seq[string], rowCallback: DataProc
): Future[Result[void, string]] {.async, gcsafe.} =
  let cleanedQuery = ($query).replace(" ", "").replace("\n", "")
  ## remove everything between ' or " all possible sequence of numbers. e.g. rm partition partition
  var querySummary = cleanedQuery.replace(re"""(['"]).*?\1""", "")
  querySummary = querySummary.replace(re"\d+", "")
  querySummary = "query_tag_" & querySummary[0 ..< min(querySummary.len, 200)]

  var queryStartTime = getTime().toUnixFloat()

  (await db.sendQuery(query, args)).isOkOr:
    return err("error in dbConnQuery calling sendQuery: " & $error)

  let sendDuration = getTime().toUnixFloat() - queryStartTime
  query_time_secs.set(sendDuration, [querySummary, "sendQuery"])

  queryStartTime = getTime().toUnixFloat()

  (await db.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQuery calling waitQueryToFinish: " & $error)

  let waitDuration = getTime().toUnixFloat() - queryStartTime
  query_time_secs.set(waitDuration, [querySummary, "waitFinish"])

  query_count.inc(labelValues = [querySummary])

  if not "insert" in ($query).toLower():
    debug "dbConnQuery",
      query = $query,
      querySummary,
      waitDurationSecs = waitDuration,
      sendDurationSecs = sendDuration

  return ok()

proc dbConnQueryPrepared*(
    db: DbConn,
    stmtName: string,
    paramValues: seq[string],
    paramLengths: seq[int32],
    paramFormats: seq[int32],
    rowCallback: DataProc,
): Future[Result[void, string]] {.async, gcsafe.} =
  var queryStartTime = getTime().toUnixFloat()
  db.sendQueryPrepared(stmtName, paramValues, paramLengths, paramFormats).isOkOr:
    return err("error in dbConnQueryPrepared calling sendQuery: " & $error)

  let sendDuration = getTime().toUnixFloat() - queryStartTime
  query_time_secs.set(sendDuration, [stmtName, "sendQuery"])

  queryStartTime = getTime().toUnixFloat()

  (await db.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQueryPrepared calling waitQueryToFinish: " & $error)

  let waitDuration = getTime().toUnixFloat() - queryStartTime
  query_time_secs.set(waitDuration, [stmtName, "waitFinish"])

  query_count.inc(labelValues = [stmtName])

  if not "insert" in stmtName.toLower():
    debug "dbConnQueryPrepared",
      stmtName, waitDurationSecs = waitDuration, sendDurationSecs = sendDuration

  return ok()
