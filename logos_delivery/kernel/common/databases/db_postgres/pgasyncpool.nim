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
import ./dbconn, ./dns_resolver, ../common, logos_delivery/kernel/core/time

type
  # Database connection pool
  PgAsyncPool* = ref object
    connStringNoHost: string
    host: string ## resolved off the event loop, see connectString
    defaultLockTimeoutMs: int64
    maxConnections: int
    connectTimeout: Duration
    sessionSettings: string
      ## SET statements run on every new connection. A startup `options`
      ## parameter would be rejected by connection poolers like PgBouncer.
    generation: int
      ## bumped by close() so that a connect in flight at that moment is dropped
    conns: seq[DbConnWrapper]
    numConnecting: int ## slots reserved by connections still being opened
    busySignal: ThreadSignalPtr ## signal to wait while the pool is busy

func serverTimeoutsSettings(statementTimeout, lockTimeout: Duration): string =
  ## Zero leaves the server default, i.e. no timeout
  var settings = newSeq[string](0)
  if statementTimeout > ZeroDuration:
    settings.add("SET statement_timeout = " & $statementTimeout.milliseconds)
  if lockTimeout > ZeroDuration:
    settings.add("SET lock_timeout = " & $lockTimeout.milliseconds)

  return settings.join("; ")

proc new*(
    T: type PgAsyncPool,
    dbUrl: string,
    maxConnections: int,
    statementTimeout = ZeroDuration,
    lockTimeout = ZeroDuration,
    connectTimeout = DefaultConnectTimeout,
): DatabaseResult[T] =
  var connString: string
  var hostName: string

  try:
    let regex = re2("""^postgres(?:ql)?:\/\/([^:]+):([^@]+)@([^:]+):(\d+)\/(.+)$""")
    var m: RegexMatch2
    if dbUrl.match(regex, m) == false:
      return err("could not properly parse dbUrl: " & dbUrl)

    let user = dbUrl[m.captures[0]]
      ## m.captures[i] contains an slice with the desired value
    let password = dbUrl[m.captures[1]]
    let host = dbUrl[m.captures[2]]
    hostName = host
    let port = dbUrl[m.captures[3]]
    let dbName = dbUrl[m.captures[4]]

    connString = fmt"user={user} port={port} dbname={dbName} password={password}"
  except KeyError, ValueError:
    return err("could not parse postgres string: " & getCurrentExceptionMsg())

  let pool = PgAsyncPool(
    connStringNoHost: connString,
    host: hostName,
    defaultLockTimeoutMs: lockTimeout.milliseconds,
    maxConnections: maxConnections,
    connectTimeout: connectTimeout,
    sessionSettings: serverTimeoutsSettings(statementTimeout, lockTimeout),
    conns: newSeq[DbConnWrapper](0),
  )

  return ok(pool)

proc close*(pool: PgAsyncPool): Future[Result[void, string]] {.async.} =
  ## Gracefully wait and close all openned connections
  # wait for the connections to be released and close them, without
  # blocking the async runtime

  debug "close PgAsyncPool"
  pool.generation.inc()
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

proc connectString(pool: PgAsyncPool): Future[DatabaseResult[string]] {.async.} =
  ## libpq would resolve a host name with a blocking lookup, so the address is
  ## handed over next to the name, which still serves certificate checks.
  let hostAddrs = (await resolveHostAddr(pool.host)).valueOr:
    return err("error resolving the database host: " & $error)

  if hostAddrs.len == 0:
    return ok(pool.connStringNoHost & " host=" & pool.host)

  ## libpq pairs the n-th host with the n-th address and tries them in order
  let numAddrs = hostAddrs.count(',') + 1
  let hosts = newSeqWith(numAddrs, pool.host).join(",")
  return ok(pool.connStringNoHost & " host=" & hosts & " hostaddr=" & hostAddrs)

proc cancelBackend(pool: PgAsyncPool, pid: int32) {.async.} =
  ## Closing the socket does not stop a command the server already runs, e.g.
  ## one waiting on a lock, so the backend is asked to cancel it.
  try:
    let connString = (await pool.connectString()).valueOr:
      error "could not build the connection string to cancel a backend",
        error = $error, pid
      return

    let conn = (await DbConnWrapper.new(connString, pool.connectTimeout)).valueOr:
      error "could not connect to cancel a backend", error = $error, pid
      return

    defer:
      conn.closeDbConn().isOkOr:
        error "failed to close the cancelling connection", error = $error

    (
      await conn.dbConnQuery(
        sql("SELECT pg_cancel_backend(" & $pid & ")"), newSeq[string](0), nil, ""
      )
    ).isOkOr:
      error "failed to cancel a backend", error = $error, pid
  except CatchableError:
    error "exception cancelling a backend", error = getCurrentExceptionMsg(), pid

proc acquireConn(pool: PgAsyncPool): Future[DatabaseResult[DbConnWrapper]] {.async.} =
  ## Waits for a free connection or opens one if the limit allows it. The
  ## connection is marked busy before returning: with several waiters woken by
  ## the same release, marking it later let two queries share one connection.
  while true:
    for conn in pool.conns:
      if not conn.isPgDbConnBusy():
        conn.markBusy()
        return ok(conn)

    if pool.conns.len + pool.numConnecting < pool.maxConnections:
      ## The slot stays reserved until the connection is in pool.conns: the
      ## session setup awaits, and a released slot would let concurrent
      ## callers open more than maxConnections.
      pool.numConnecting.inc()
      let generation = pool.generation
      var conn: DbConnWrapper = nil
      try:
        let connString = (await pool.connectString()).valueOr:
          return err("error building the connection string: " & $error)
        conn = (await DbConnWrapper.new(connString, pool.connectTimeout)).valueOr:
          return err("error creating DbConnWrapper: " & $error)

        if pool.sessionSettings.len > 0:
          (
            await conn.dbConnQuery(
              sql(pool.sessionSettings), newSeq[string](0), nil, requestId = ""
            )
          ).isOkOr:
            conn.closeDbConn().isOkOr:
              error "failed to close a connection after failed setup", error = $error
            return err("could not apply the session settings: " & $error)

        conn.lockTimeoutMs = pool.defaultLockTimeoutMs

        if generation != pool.generation:
          ## close() ran meanwhile, so this connection would never be closed
          conn.closeDbConn().isOkOr:
            error "failed to close a connection opened during close", error = $error
          return err("the pool was closed while connecting")

        conn.markBusy()
        pool.conns.add(conn)
        return ok(conn)
      except CancelledError as exc:
        ## Not in pool.conns yet, so nothing else would ever close it
        if not conn.isNil():
          conn.closeDbConn().isOkOr:
            error "failed to close a connection after cancelled setup", error = $error
        raise exc
      finally:
        pool.numConnecting.dec()

    let busyFuts = pool.conns.mapIt(FutureBase(it.futBecomeFree))
    if busyFuts.len == 0:
      ## every slot is still connecting
      await sleepAsync(10.milliseconds)
    else:
      discard await race(busyFuts)

proc releaseConn(pool: PgAsyncPool, conn: DbConnWrapper) =
  ## A connection whose command is still in flight in libpq, e.g. because the
  ## query was cancelled, or whose backend is gone is dropped instead of being
  ## handed out again, which failed with "another command is already in progress".
  if not conn.isReusable():
    let cancelPid =
      if conn.isCommandInFlight():
        conn.backendPid()
      else:
        0'i32
    conn.closeDbConn().isOkOr:
      error "failed to close a connection that cannot be reused", error = $error
    pool.conns.keepItIf(it != conn)

    if cancelPid != 0:
      asyncSpawn pool.cancelBackend(cancelPid)

  conn.markFree()

proc resetConnPool*(pool: PgAsyncPool): Future[DatabaseResult[void]] {.async.} =
  ## Forces closing the connection pool.
  ## This proc is intended to be called when the connection with the database
  ## got interrupted from the database side or a connectivity problem happened.

  (await pool.close()).isOkOr:
    return err("error in resetConnPool: " & error)

  return ok()

const SlowQueryThreshold = 1.seconds

proc applyLockTimeout(
    pool: PgAsyncPool, conn: DbConnWrapper, lockTimeout: Opt[Duration]
): Future[DatabaseResult[void]] {.async.} =
  ## A pooled connection keeps the lock_timeout of its last use, so the
  ## statement is only sent when it differs from what the caller wants.
  let wantedMs =
    if lockTimeout.isSome():
      lockTimeout.get().milliseconds
    else:
      pool.defaultLockTimeoutMs

  if conn.lockTimeoutMs == wantedMs:
    return ok()

  (
    await conn.dbConnQuery(
      sql("SET lock_timeout = " & $wantedMs), newSeq[string](0), nil, ""
    )
  ).isOkOr:
    return err("could not set the lock timeout: " & $error)

  conn.lockTimeoutMs = wantedMs
  return ok()

proc pgQuery*(
    pool: PgAsyncPool,
    query: string,
    args: seq[string] = newSeq[string](0),
    rowCallback: DataProc = nil,
    requestId: string = "",
    lockTimeout = Opt.none(Duration),
): Future[DatabaseResult[void]] {.async.} =
  let dbConnWrapper = (await pool.acquireConn()).valueOr:
    return err("connRes.isErr in query: " & $error)
  defer:
    pool.releaseConn(dbConnWrapper)

  (await pool.applyLockTimeout(dbConnWrapper, lockTimeout)).isOkOr:
    return err("error in asyncpool query: " & $error)

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
    lockTimeout = Opt.none(Duration),
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

  (await pool.applyLockTimeout(dbConnWrapper, lockTimeout)).isOkOr:
    return err("Error in runStmt: " & $error)

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
