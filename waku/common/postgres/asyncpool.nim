# Simple async pool driver for postgress.
# Inspired by: https://github.com/treeform/pg/
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  stew/results,
  chronicles,
  chronos
import
  ./connection,
  ./pg_asyncpool_opts

logScope:
  topics = "postgres asyncpool"

type PgAsyncPoolState {.pure.} = enum
    Closed,
    Live,
    Closing

type
  PgDbConn* = object
    dbConn*: DbConn
    busy*: bool

type
  ## Database connection pool
  PgAsyncPool* = ref object
    connOptions: PgConnOptions
    poolOptions: PgAsyncPoolOptions

    state: PgAsyncPoolState
    conns: seq[PgDbConn]

func isClosing*(pool: PgAsyncPool): bool =
  pool.state == PgAsyncPoolState.Closing

func isLive*(pool: PgAsyncPool): bool =
  pool.state == PgAsyncPoolState.Live

func isBusy*(pool: PgAsyncPool): bool =
  pool.conns.mapIt(it.busy).allIt(it)

proc close*(pool: var PgAsyncPool):
            Future[Result[void, string]] {.async.} =
  ## Gracefully wait and close all openned connections
  if pool.state == PgAsyncPoolState.Closing:
    while true:
      await sleepAsync(5.milliseconds) # Do not block the async runtime
    return ok()

  pool.state = PgAsyncPoolState.Closing

  # wait for the connections to be released and close them, without
  # blocking the async runtime
  while pool.conns.anyIt(it.busy):
    await sleepAsync(5.milliseconds)

    for i in 0..<pool.conns.len:
      if pool.conns[i].busy:
        continue

      pool.conns[i].busy = false
      pool.conns[i].dbConn.close()

proc forceClose(pool: var PgAsyncPool) =
  ## Close all the connections in the pool.
  for i in 0..<pool.conns.len:
    pool.conns[i].busy = false
    try:
      pool.conns[i].dbConn.close()
    except DbError,ValueError:
      debug "exception in forceClose: " &
            getCurrentExceptionMsg()

  pool.state = PgAsyncPoolState.Closed

proc newConnPool*(connOptions: PgConnOptions,
                  poolOptions: PgAsyncPoolOptions):
                  Result[PgAsyncPool, string] =
  ## Create a new connection pool.
  var pool = PgAsyncPool(
    connOptions: connOptions,
    poolOptions: poolOptions,
    state: PgAsyncPoolState.Live,
    conns: newSeq[PgDbConn](poolOptions.minConnections),
  )

  for i in 0..<poolOptions.minConnections:
    var connRes:Result[DbConn, string]
    try:
      connRes = open(connOptions)
    except DbError,ValueError:
      return err("exception in open: " &
                 getCurrentExceptionMsg())

    # Teardown the opened connections if we failed to open all of them
    if connRes.isErr():
      pool.forceClose()
      return err(connRes.error)

    pool.conns[i].dbConn = connRes.get()
    pool.conns[i].busy = false

  return ok(pool)

proc getConn*(pool: var PgAsyncPool):
              Future[Result[DbConn, string]] {.async.} =
  ## Wait for a free connection or create if max connections limits have not been reached.
  if not pool.isLive():
    return err("pool is not live")

  # stablish new connections if we are under the limit
  if pool.isBusy() and pool.conns.len < pool.poolOptions.maxConnections:
    let connRes = open(pool.connOptions)
    if connRes.isOk():
      let conn = connRes.get()
      pool.conns.add(PgDbConn(dbConn: conn, busy: true))
      return ok(conn)
    else:
      warn "failed to stablish a new connection", msg = connRes.error

  # wait for a free connection without blocking the async runtime
  while pool.isBusy():
    await sleepAsync(5.milliseconds)

  for index in 0..<pool.conns.len:
    if pool.conns[index].busy:
      continue

    pool.conns[index].busy = true
    return ok(pool.conns[index].dbConn)

proc releaseConn(pool: var PgAsyncPool,
                 conn: DbConn) =
  ## Mark the connection as released.
  for i in 0..<pool.conns.len:
    if pool.conns[i].dbConn == conn:
      pool.conns[i].busy = false

proc query*(pool: var PgAsyncPool,
            query: SqlQuery,
            args: seq[string]):
            Future[Result[seq[Row], string]] {.async.} =
  ## Runs the SQL query getting results.
  let connRes = await pool.getConn()
  if connRes.isErr():
    return Result[seq[Row], string].err(connRes.error())

  let conn = connRes.get()
  defer: pool.releaseConn(conn)

  return await conn.rows(query, args)

proc exec*(pool: var PgAsyncPool,
           query: SqlQuery,
           args: seq[string]):
           Future[Result[void, string]] {.async.} =
  ## Runs the SQL query without results.
  let connRes = await pool.getConn()
  if connRes.isErr():
    return Result[void, string].err(connRes.error())

  let conn = connRes.get()
  defer: pool.releaseConn(conn)

  let rowsRes = await conn.rows(query, args)
  if rowsRes.isErr():
    return Result[void, string].err(rowsRes.error())

  return Result[void, string].ok()
