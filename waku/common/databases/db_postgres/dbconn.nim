import std/[times, strutils], results, chronos

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

  ok(conn)

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

  while db.pqisBusy() == 1:
    ## TODO: Enhance performance in concurrent queries.
    ## The connection keeps busy for quite a long time when performing intense concurrect queries.
    ## For example, a given query can last 11 milliseconds within from the database point of view
    ## but, on the other hand, the connection remains in "db.pqisBusy() == 1" for 100ms more.
    ## I think this is because `nwaku` is single-threaded and it has to handle many connections (20)
    ## simultaneously. Therefore, there is an underlying resource sharing (cpu) that makes this
    ## to happen. Notice that the _Postgres_ database spawns one process per each connection.
    let success = db.pqconsumeInput()

    if success != 1:
      db.check().isOkOr:
        return err("failed pqconsumeInput: " & $error)

      return err("failed pqconsumeInput: unknown reason")

    await sleepAsync(timer.milliseconds(0)) # Do not block the async runtime

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
  (await db.sendQuery(query, args)).isOkOr:
    return err("error in dbConnQuery calling sendQuery: " & $error)

  (await db.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQuery calling waitQueryToFinish: " & $error)

  return ok()

proc dbConnQueryPrepared*(
    db: DbConn,
    stmtName: string,
    paramValues: seq[string],
    paramLengths: seq[int32],
    paramFormats: seq[int32],
    rowCallback: DataProc,
): Future[Result[void, string]] {.async, gcsafe.} =
  db.sendQueryPrepared(stmtName, paramValues, paramLengths, paramFormats).isOkOr:
    return err("error in dbConnQueryPrepared calling sendQuery: " & $error)

  (await db.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQueryPrepared calling waitQueryToFinish: " & $error)

  return ok()
