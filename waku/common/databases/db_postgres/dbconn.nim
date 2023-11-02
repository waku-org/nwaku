import
  std/[times, strutils, strformat],
  stew/results,
  chronos

include db_postgres

type DataProc* = proc(result: ptr PGresult) {.closure, gcsafe.}

## Connection management

proc isBusy*(db: DbConn): bool =
  try:
    return db.pqisBusy() == 1
  except ValueError,DbError:
    return true

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect,DbError].}
else:
  {.push raises: [ValueError,DbError].}

proc check*(db: DbConn): Result[void, string] =

  var message: string
  try:
    message = $db.pqErrorMessage()
  except ValueError,DbError:
    return err("exception in check: " & getCurrentExceptionMsg())

  if message.len > 0:
    return err($message)

  return ok()

proc open*(connString: string):
           Result[DbConn, string] =
  ## Opens a new connection.
  var conn: DbConn = nil
  try:
    conn = open("","", "", connString)
  except DbError:
    return err("exception opening new connection: " &
               getCurrentExceptionMsg())

  if conn.status != CONNECTION_OK:
    let checkRes = conn.check()
    if checkRes.isErr():
      return err("failed to connect to database: " & checkRes.error)

    return err("unknown reason")

  ok(conn)

proc sendQuery(db: DbConn,
               query: SqlQuery,
               args: seq[string]):
               Future[Result[void, string]] {.async.} =
  ## This proc can be used directly for queries that don't retrieve values back.

  if db.status != CONNECTION_OK:
    let checkRes = db.check()
    if checkRes.isErr():
      return err("failed to connect to database: " & checkRes.error)

    return err("unknown reason")

  var wellFormedQuery = ""
  try:
    wellFormedQuery = dbFormat(query, args)
  except DbError:
    return err("exception formatting the query: " &
               getCurrentExceptionMsg())

  let success = db.pqsendQuery(cstring(wellFormedQuery))
  if success != 1:
    let checkRes = db.check()
    if checkRes.isErr():
      return err("failed pqsendQuery: " & checkRes.error)

    return err("failed pqsendQuery: unknown reason")

  return ok()

proc sendQueryPrepared(
               db: DbConn,
               stmtName: string,
               paramValues: openArray[string],
               paramLengths: openArray[int32],
               paramFormats: openArray[int32]):
               Result[void, string] =
  ## This proc can be used directly for queries that don't retrieve values back.

  if paramValues.len != paramLengths.len or paramValues.len != paramFormats.len or
     paramLengths.len != paramFormats.len:
    let lengthsErrMsg = $paramValues.len & " " & $paramLengths.len & " " & $paramFormats.len
    return err("lengths discrepancies in sendQueryPrepared: " & $lengthsErrMsg)

  if db.status != CONNECTION_OK:
    let checkRes = db.check()
    if checkRes.isErr():
      return err("failed to connect to database: " & checkRes.error)

    return err("unknown reason")

  var cstrArrayParams = allocCStringArray(paramValues)
  defer: deallocCStringArray(cstrArrayParams)

  let nParams = cast[int32](paramValues.len)

  const ResultFormat = 0 ## 0 for text format, 1 for binary format.

  let success = db.pqsendQueryPrepared(stmtName,
                                       nParams,
                                       cstrArrayParams,
                                       unsafeAddr paramLengths[0],
                                       unsafeAddr paramFormats[0],
                                       ResultFormat)
  if success != 1:
    let checkRes = db.check()
    if checkRes.isErr():
      return err("failed pqsendQueryPrepared: " & checkRes.error)

    return err("failed pqsendQueryPrepared: unknown reason")

  return ok()

proc waitQueryToFinish(db: DbConn,
                       rowCallback: DataProc = nil):
                       Future[Result[void, string]] {.async.} =
  ## The 'rowCallback' param is != nil when the underlying query wants to retrieve results (SELECT.)
  ## For other queries, like "INSERT", 'rowCallback' should be nil.

  while db.isBusy():

    let success = db.pqconsumeInput()

    if success != 1:
      let checkRes = db.check()
      if checkRes.isErr():
        return err("failed pqconsumeInput: " & checkRes.error)

      return err("failed pqconsumeInput: unknown reason")

    await sleepAsync(timer.milliseconds(0)) # Do not block the async runtime

  ## Now retrieve the result
  while true:
    let pqResult = db.pqgetResult()

    if pqResult == nil:
      # Check if its a real error or just end of results
      let checkRes = db.check()
      if checkRes.isErr():
        return err("error in rows: " & checkRes.error)

      return ok() # reached the end of the results

    if not rowCallback.isNil():
      rowCallback(pqResult)

    pqclear(pqResult)

proc dbConnQuery*(db: DbConn,
                  query: SqlQuery,
                  args: seq[string],
                  rowCallback: DataProc):
                  Future[Result[void, string]] {.async, gcsafe.} =

  (await db.sendQuery(query, args)).isOkOr:
    return err("error in dbConnQuery calling sendQuery: " & $error)

  (await db.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQuery calling waitQueryToFinish: " & $error)

  return ok()

proc dbConnQueryPrepared*(db: DbConn,
                          stmtName: string,
                          paramValues: seq[string],
                          paramLengths: seq[int32],
                          paramFormats: seq[int32],
                          rowCallback: DataProc):
                          Future[Result[void, string]] {.async, gcsafe.} =

  db.sendQueryPrepared(stmtName, paramValues , paramLengths, paramFormats).isOkOr:
    return err("error in dbConnQueryPrepared calling sendQuery: " & $error)

  (await db.waitQueryToFinish(rowCallback)).isOkOr:
    return err("error in dbConnQueryPrepared calling waitQueryToFinish: " & $error)

  return ok()
