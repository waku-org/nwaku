when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect,DbError].}
else:
  {.push raises: [DbError,ValueError].}

import
  stew/results,
  chronicles,
  chronos

include db_postgres

logScope:
  topics = "postgres connection"

type PgConnOptions* = object
  ## Connection options
  connection*: string
  user*: string
  password*: string
  database*: string

func init*(T: type PgConnOptions,
           connection,
           user,
           password,
           database: string):
           T =
  PgConnOptions(
    connection: connection,
    user: user,
    password: password,
    database: database
  )

## Connection management

proc error(db: DbConn): string =
  ## Extract the error message from the database connection.
  $pqErrorMessage(db)

proc open*(options: PgConnOptions):
           Result[DbConn, string] =
  ## Opens a new connection.
  var conn:DbConn = nil
  try:
    conn = open(
      options.connection,
      options.user,
      options.password,
      options.database
    )
  except DbError:
    return err("exception opening new connection: " &
               getCurrentExceptionMsg())

  if conn.status != CONNECTION_OK:
    var reason = conn.error
    if reason.len > 0:
      reason = "unknown reason"

    return err("failed to connect to database: " & reason)

  ok(conn)

proc rows*(db: DbConn,
           query: SqlQuery,
           args: seq[string]):
           Future[Result[seq[Row], string]] {.async.} =
  ## Runs the SQL getting results.
  if db.status != CONNECTION_OK:
    return err("connection is not ok: " & db.error)

  var wellFormedQuery = ""
  try:
    wellFormedQuery = dbFormat(query, args)
  except DbError:
    return err("exception formatting the query: " &
               getCurrentExceptionMsg())

  let success = pqsendQuery(db, wellFormedQuery)
  if success != 1:
    return err(db.error)

  while true:
    let success = pqconsumeInput(db)
    if success != 1:
      return err(db.error)

    if pqisBusy(db) == 1:
      await sleepAsync(0.milliseconds) # Do not block the async runtime
      continue

    var pqResult = pqgetResult(db)
    if pqResult == nil and db.error.len > 0:
      # Check if its a real error or just end of results
      return err(db.error)

    var rows: seq[Row]

    var cols = pqnfields(pqResult)
    var row = newRow(cols)
    for i in 0'i32..pqNtuples(pqResult) - 1:
      setRow(pqResult, row, i, cols)
      rows.add(row)

    pqclear(pqResult)
