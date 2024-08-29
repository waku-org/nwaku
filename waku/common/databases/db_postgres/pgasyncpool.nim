# Simple async pool driver for postgress.
# Inspired by: https://github.com/treeform/pg/
{.push raises: [].}

import std/[sequtils, nre, strformat, sets], results, chronos, chronicles
import ./dbconn, ../common, ../../../waku_core/time

type PgAsyncPoolState {.pure.} = enum
  Closed
  Live
  Closing

type PgDbConn = object
  dbConn: DbConn
  open: bool
  busy: bool
  preparedStmts: HashSet[string] ## [stmtName's]

type
  # Database connection pool
  PgAsyncPool* = ref object
    connString: string
    maxConnections: int

    state: PgAsyncPoolState
    conns: seq[PgDbConn]

proc new*(T: type PgAsyncPool, dbUrl: string, maxConnections: int): DatabaseResult[T] =
  var connString: string

  try:
    let regex = re("""^postgres:\/\/([^:]+):([^@]+)@([^:]+):(\d+)\/(.+)$""")
    let matches = find(dbUrl, regex).get.captures
    let user = matches[0]
    let password = matches[1]
    let host = matches[2]
    let port = matches[3]
    let dbName = matches[4]
    connString =
      fmt"user={user} host={host} port={port} dbname={dbName} password={password}"
  except KeyError, InvalidUnicodeError, RegexInternalError, ValueError, StudyError,
      SyntaxError:
    return err("could not parse postgres string: " & getCurrentExceptionMsg())

  let pool = PgAsyncPool(
    connString: connString,
    maxConnections: maxConnections,
    state: PgAsyncPoolState.Live,
    conns: newSeq[PgDbConn](0),
  )

  return ok(pool)

func isLive(pool: PgAsyncPool): bool =
  pool.state == PgAsyncPoolState.Live

func isBusy(pool: PgAsyncPool): bool =
  pool.conns.mapIt(it.busy).allIt(it)

proc close*(pool: PgAsyncPool): Future[Result[void, string]] {.async.} =
  ## Gracefully wait and close all openned connections

  if pool.state == PgAsyncPoolState.Closing:
    while pool.state == PgAsyncPoolState.Closing:
      await sleepAsync(0.milliseconds) # Do not block the async runtime
    return ok()

  pool.state = PgAsyncPoolState.Closing

  # wait for the connections to be released and close them, without
  # blocking the async runtime
  while pool.conns.anyIt(it.busy):
    await sleepAsync(0.milliseconds)

    for i in 0 ..< pool.conns.len:
      if pool.conns[i].busy:
        continue

      if pool.conns[i].open:
        pool.conns[i].dbConn.close()
        pool.conns[i].busy = false
        pool.conns[i].open = false

  for i in 0 ..< pool.conns.len:
    if pool.conns[i].open:
      pool.conns[i].dbConn.close()

  pool.conns.setLen(0)
  pool.state = PgAsyncPoolState.Closed

  return ok()

proc getFirstFreeConnIndex(pool: PgAsyncPool): DatabaseResult[int] =
  for index in 0 ..< pool.conns.len:
    if pool.conns[index].busy:
      continue

    ## Pick up the first free connection and set it busy
    pool.conns[index].busy = true
    return ok(index)

proc getConnIndex(pool: PgAsyncPool): Future[DatabaseResult[int]] {.async.} =
  ## Waits for a free connection or create if max connections limits have not been reached.
  ## Returns the index of the free connection

  if not pool.isLive():
    return err("pool is not live")

  if not pool.isBusy():
    return pool.getFirstFreeConnIndex()

  ## Pool is busy then

  if pool.conns.len == pool.maxConnections:
    ## Can't create more connections. Wait for a free connection without blocking the async runtime.
    while pool.isBusy():
      await sleepAsync(0.milliseconds)

    return pool.getFirstFreeConnIndex()
  elif pool.conns.len < pool.maxConnections:
    ## stablish a new connection
    let conn = dbconn.open(pool.connString).valueOr:
      return err("failed to stablish a new connection: " & $error)

    pool.conns.add(
      PgDbConn(
        dbConn: conn, open: true, busy: true, preparedStmts: initHashSet[string]()
      )
    )
    return ok(pool.conns.len - 1)

proc resetConnPool*(pool: PgAsyncPool): Future[DatabaseResult[void]] {.async.} =
  ## Forces closing the connection pool.
  ## This proc is intended to be called when the connection with the database
  ## got interrupted from the database side or a connectivity problem happened.

  for i in 0 ..< pool.conns.len:
    pool.conns[i].busy = false

  (await pool.close()).isOkOr:
    return err("error in resetConnPool: " & error)

  pool.state = PgAsyncPoolState.Live
  return ok()

proc releaseConn(pool: PgAsyncPool, conn: DbConn) =
  ## Marks the connection as released.
  for i in 0 ..< pool.conns.len:
    if pool.conns[i].dbConn == conn:
      pool.conns[i].busy = false

const SlowQueryThresholdInNanoSeconds = 2_000_000_000

proc pgQuery*(
    pool: PgAsyncPool,
    query: string,
    args: seq[string] = newSeq[string](0),
    rowCallback: DataProc = nil,
    requestId: string = "",
): Future[DatabaseResult[void]] {.async.} =
  let connIndex = (await pool.getConnIndex()).valueOr:
    return err("connRes.isErr in query: " & $error)

  let queryStartTime = getNowInNanosecondTime()
  let conn = pool.conns[connIndex].dbConn
  defer:
    pool.releaseConn(conn)
    let queryDuration = getNowInNanosecondTime() - queryStartTime
    if queryDuration > SlowQueryThresholdInNanoSeconds:
      debug "pgQuery slow query",
        query_duration_secs = (queryDuration / 1_000_000_000), query, requestId

  (await conn.dbConnQuery(sql(query), args, rowCallback)).isOkOr:
    return err("error in asyncpool query: " & $error)

  return ok()

proc runStmt*(
    pool: PgAsyncPool,
    stmtName: string,
    stmtDefinition: string,
    paramValues: seq[string],
    paramLengths: seq[int32],
    paramFormats: seq[int32],
    rowCallback: DataProc = nil,
    requestId: string = "",
): Future[DatabaseResult[void]] {.async.} =
  ## Runs a stored statement, for performance purposes.
  ## The stored statements are connection specific and is a technique of caching a very common
  ## queries within the same connection.
  ##
  ## rowCallback != nil when it is expected to retrieve info from the database.
  ## rowCallback == nil for queries that change the database state.

  let connIndex = (await pool.getConnIndex()).valueOr:
    return err("Error in runStmt: " & $error)

  let conn = pool.conns[connIndex].dbConn
  let queryStartTime = getNowInNanosecondTime()

  defer:
    pool.releaseConn(conn)
    let queryDuration = getNowInNanosecondTime() - queryStartTime
    if queryDuration > SlowQueryThresholdInNanoSeconds:
      debug "runStmt slow query",
        query_duration = queryDuration / 1_000_000_000,
        query = stmtDefinition,
        requestId

  if not pool.conns[connIndex].preparedStmts.contains(stmtName):
    # The connection doesn't have that statement yet. Let's create it.
    # Each session/connection has its own prepared statements.
    let res = catch:
      let len = paramValues.len
      discard conn.prepare(stmtName, sql(stmtDefinition), len)

    if res.isErr():
      return err("failed prepare in runStmt: " & res.error.msg)

    pool.conns[connIndex].preparedStmts.incl(stmtName)

  (
    await conn.dbConnQueryPrepared(
      stmtName, paramValues, paramLengths, paramFormats, rowCallback
    )
  ).isOkOr:
    return err("error in runStmt: " & $error)

  return ok()
