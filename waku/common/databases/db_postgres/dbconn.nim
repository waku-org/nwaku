when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect,DbError].}
else:
  {.push raises: [ValueError,DbError].}

import
  stew/results,
  chronos

include db_postgres

type DataProc* = proc(result: ptr PGresult) {.closure, gcsafe.}

## Connection management

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

proc waitQueryToFinish(db: DbConn,
                       rowCallback: DataProc = nil):
                       Future[Result[void, string]] {.async.} =
  ## The 'rowCallback' param is != nil when the underlying query wants to retrieve results (SELECT.)
  ## For other queries, like "INSERT", 'rowCallback' should be nil.

  while true:

    let success = db.pqconsumeInput()
    if success != 1:
      let checkRes = db.check()
      if checkRes.isErr():
        return err("failed pqconsumeInput: " & checkRes.error)

      return err("failed pqconsumeInput: unknown reason")

    if db.pqisBusy() == 1:
      await sleepAsync(timer.milliseconds(0)) # Do not block the async runtime
      continue

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
