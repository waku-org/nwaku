# Simple async pool driver for postgress.
# Inspired by: https://github.com/treeform/pg/
{.push raises: [].}

import
  std/[sequtils, strformat],
  regex,
  results,
  chronos,
  chronos/threadsync,
  chronicles,
  strutils
import ./dbconn, ../common, ../../../waku_core/time

type
  # Database connection pool
  PgAsyncPool* = ref object
    connString: string
    maxConnections: int
    conns: seq[DbConnWrapper]
    busySignal: ThreadSignalPtr ## signal to wait while the pool is busy

proc new*(T: type PgAsyncPool, dbUrl: string, maxConnections: int): DatabaseResult[T] =
  var connString: string

  try:
    let regex = re2("""^postgres(?:ql)?:\/\/([^:]+):([^@]+)@([^:]+):(\d+)\/(.+)$""")
    var m: RegexMatch2
    if dbUrl.match(regex, m) == false:
      return err("could not properly parse dbUrl: " & dbUrl)

    let user = dbUrl[m.captures[0]]
      ## m.captures[i] contains an slice with the desired value
    let password = dbUrl[m.captures[1]]
    let host = dbUrl[m.captures[2]]
    let port = dbUrl[m.captures[3]]
    let dbName = dbUrl[m.captures[4]]

    connString =
      fmt"user={user} host={host} port={port} dbname={dbName} password={password}"
  except KeyError, ValueError:
    return err("could not parse postgres string: " & getCurrentExceptionMsg())

  let pool = PgAsyncPool(
    connString: connString,
    maxConnections: maxConnections,
    conns: newSeq[DbConnWrapper](0),
  )

  return ok(pool)

proc close*(pool: PgAsyncPool): Future[Result[void, string]] {.async.} =
  ## Gracefully wait and close all openned connections
  # wait for the connections to be released and close them, without
  # blocking the async runtime

  debug "close PgAsyncPool"
  ## a connection that never ran a query has no futBecomeFree to wait for
  await allFutures(
    pool.conns.filterIt(not it.futBecomeFree.isNil()).mapIt(it.futBecomeFree)
  )
  debug "closing all connection PgAsyncPool"

  var closeErrors = newSeq[string](0)
  for i in 0 ..< pool.conns.len:
    ## one connection that cannot be closed must not keep the others open
    ## and registered in the dispatcher
    pool.conns[i].closeDbConn().isOkOr:
      closeErrors.add($error)

  pool.conns.setLen(0)

  if closeErrors.len > 0:
    return err("error in close PgAsyncPool: " & closeErrors.join("; "))

  return ok()

proc acquireConn(pool: PgAsyncPool): Future[DatabaseResult[DbConnWrapper]] {.async.} =
  ## Waits for a free connection or opens one if the limit allows it. The
  ## connection is marked busy before returning: with several waiters woken by
  ## the same release, marking it later let two queries share one connection.
  while true:
    for conn in pool.conns:
      if not conn.isPgDbConnBusy():
        conn.markBusy()
        return ok(conn)

    if pool.conns.len < pool.maxConnections:
      let conn = DbConnWrapper.new(pool.connString).valueOr:
        return err("error creating DbConnWrapper: " & $error)

      conn.markBusy()
      pool.conns.add(conn)
      return ok(conn)

    discard await race(pool.conns.mapIt(FutureBase(it.futBecomeFree)))

proc releaseConn(pool: PgAsyncPool, conn: DbConnWrapper) =
  ## A connection whose command is still in flight in libpq, e.g. because the
  ## query was cancelled, or whose backend is gone is dropped instead of being
  ## handed out again, which failed with "another command is already in progress".
  if not conn.isReusable():
    conn.closeDbConn().isOkOr:
      error "failed to close a connection that cannot be reused", error = $error
    pool.conns.keepItIf(it != conn)

  conn.markFree()

proc resetConnPool*(pool: PgAsyncPool): Future[DatabaseResult[void]] {.async.} =
  ## Forces closing the connection pool.
  ## This proc is intended to be called when the connection with the database
  ## got interrupted from the database side or a connectivity problem happened.

  (await pool.close()).isOkOr:
    return err("error in resetConnPool: " & error)

  return ok()

const SlowQueryThreshold = 1.seconds

proc pgQuery*(
    pool: PgAsyncPool,
    query: string,
    args: seq[string] = newSeq[string](0),
    rowCallback: DataProc = nil,
    requestId: string = "",
): Future[DatabaseResult[void]] {.async.} =
  let dbConnWrapper = (await pool.acquireConn()).valueOr:
    return err("connRes.isErr in query: " & $error)
  defer:
    pool.releaseConn(dbConnWrapper)

  let queryStartTime = getNowInNanosecondTime()
  defer:
    let queryDuration = getNowInNanosecondTime() - queryStartTime
    if queryDuration > SlowQueryThreshold.nanos:
      debug "pgQuery slow query",
        query_duration_secs = (queryDuration / 1_000_000_000), query, requestId

  (await dbConnWrapper.dbConnQuery(sql(query), args, rowCallback, requestId)).isOkOr:
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

  let dbConnWrapper = (await pool.acquireConn()).valueOr:
    return err("Error in runStmt: " & $error)
  defer:
    pool.releaseConn(dbConnWrapper)

  let queryStartTime = getNowInNanosecondTime()

  defer:
    let queryDuration = getNowInNanosecondTime() - queryStartTime
    if queryDuration > SlowQueryThreshold.nanos:
      debug "runStmt slow query",
        query_duration = queryDuration / 1_000_000_000,
        query = stmtDefinition,
        requestId

  if not dbConnWrapper.containsPreparedStmt(stmtName):
    # The connection doesn't have that statement yet. Let's create it.
    # Each session/connection has its own prepared statements.
    (await dbConnWrapper.dbConnPrepare(stmtName, stmtDefinition, paramValues.len)).isOkOr:
      return err("failed prepare in runStmt: " & $error)

    dbConnWrapper.inclPreparedStmt(stmtName)

  (
    await dbConnWrapper.dbConnQueryPrepared(
      stmtName, paramValues, paramLengths, paramFormats, rowCallback, requestId
    )
  ).isOkOr:
    return err("error in runStmt: " & $error)

  return ok()
