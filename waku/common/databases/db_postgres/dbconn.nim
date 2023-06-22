when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect,DbError].}
else:
  {.push raises: [ValueError,DbError].}

import
  stew/results,
  chronos

include db_postgres

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

proc rows*(db: DbConn,
           query: SqlQuery,
           args: seq[string]):
           Future[Result[seq[Row], string]] {.async.} =
  ## Runs the SQL getting results.

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

  var ret = newSeq[Row](0)

  while true:

    let success = db.pqconsumeInput()
    if success != 1:
      let checkRes = db.check()
      if checkRes.isErr():
        return err("failed pqconsumeInput: " & checkRes.error)

      return err("failed pqconsumeInput: unknown reason")

    if db.pqisBusy() == 1:
      await sleepAsync(0.milliseconds) # Do not block the async runtime
      continue

    var pqResult = db.pqgetResult()
    if pqResult == nil:
      # Check if its a real error or just end of results
      let checkRes = db.check()
      if checkRes.isErr():
        return err("error in rows: " & checkRes.error)

      return ok(ret) # reached the end of the results

    var cols = pqResult.pqnfields()
    var row = cols.newRow()
    for i in 0'i32 .. pqResult.pqNtuples() - 1:
      pqResult.setRow(row, i, cols) # puts the value in the row
      ret.add(row)

    pqclear(pqResult)
