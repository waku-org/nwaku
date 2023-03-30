when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  chronicles,
  chronos

import ./common

include db_postgres


logScope:
  topics = "postgres connection"


## Connection options

type PgConnOptions* = object
    connection: string
    user: string
    password: string
    database: string

func init*(T: type PgConnOptions, connection, user, password, database: string): T =
  PgConnOptions(
    connection: connection,
    user: user,
    password: password,
    database: database
  )

func connection*(options: PgConnOptions): string =
  options.connection

func user*(options: PgConnOptions): string =
  options.user

func password*(options: PgConnOptions): string =
  options.password

func database*(options: PgConnOptions): string =
  options.database


## Connection management

proc error(db: DbConn): string =
  ## Extract the error message from the database connection.
  $pqErrorMessage(db)


proc open*(options: PgConnOptions): common.PgResult[DbConn] =
  ## Open a new connection.
  let conn = open(
    options.connection,
    options.user,
    options.password,
    options.database
  )

  if conn.status != CONNECTION_OK:
    var reason = conn.error
    if reason.len > 0:
      reason = "unknown reason"

    return err("failed to connect to database: " & reason)

  ok(conn)


proc rows*(db: DbConn, query: SqlQuery, args: seq[string]): Future[common.PgResult[seq[Row]]] {.async.} =
  ## Runs the SQL getting results.
  if db.status != CONNECTION_OK:
    return err("connection is not ok: " & db.error)

  let success = pqsendQuery(db, dbFormat(query, args))
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
