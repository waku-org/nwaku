{.used.}

## Reproduces the event-loop freeze seen in production: a first-time `prepare`
## in `PgAsyncPool.runStmt` is a synchronous libpq call, so when it has to wait
## for a lock on `messages_lookup` (queued behind a partition DDL) the whole
## chronos event loop stops.

import
  std/[atomics, os, strutils, typedthreads],
  results,
  testutils/unittests,
  chronos,
  db_connector/[db_postgres, postgres]
import
  logos_delivery/waku/[
    waku_archive/driver/postgres_driver,
    waku_core,
    waku_core/message/digest,
    common/databases/db_postgres/pgasyncpool,
  ],
  ../testlib/wakucore,
  ../testlib/testasync,
  ../testlib/postgres

const
  RawConnString =
    "user=postgres host=localhost port=5432 dbname=postgres password=test123"
  TickInterval = 100.milliseconds
  MaxAcceptedLoopGap = 500.milliseconds
  LockHoldMs = 2000
  WatchdogTimeoutMs = 3000
  PollTimeoutMs = 5000

type
  LoopProbe = ref object
    running: bool
    last: Moment
    maxGap: Duration

  ReleaseArgs = object
    conn: DbConn
    delayMs: int

var
  putDone: Atomic[bool]
  watchdogFired: Atomic[bool]

proc tick(probe: LoopProbe) {.async.} =
  probe.last = Moment.now()
  while probe.running:
    await sleepAsync(TickInterval)
    let now = Moment.now()
    if now - probe.last > probe.maxGap:
      probe.maxGap = now - probe.last
    probe.last = now

proc openRaw(): DbConn =
  return open("", "", "", RawConnString)

proc pollUntil(observer: DbConn, query: string): bool =
  ## Synchronous on purpose: it only orders the server-side state before the
  ## code under test runs.
  var waitedMs = 0
  while waitedMs < PollTimeoutMs:
    if observer.getValue(sql(query)).parseInt() > 0:
      return true
    sleep(10)
    waitedMs += 10
  return false

proc drainResults(conn: DbConn) =
  while true:
    let res = conn.pqgetResult()
    if res.isNil():
      return
    pqclear(res)

proc commitAfter(args: ReleaseArgs) {.thread.} =
  ## Runs on its own OS thread: a chronos timer could not fire while the loop
  ## is blocked.
  sleep(args.delayMs)
  discard args.conn.tryExec(sql"COMMIT")

proc cancelDdlIfStuck(timeoutMs: int) {.thread.} =
  ## Breaks the lock cycle so that the test always terminates.
  var waitedMs = 0
  while waitedMs < timeoutMs:
    if putDone.load():
      return
    sleep(10)
    waitedMs += 10

  watchdogFired.store(true)
  let conn = open("", "", "", RawConnString)
  defer:
    conn.close()
  discard conn.tryExec(
    sql"""SELECT pg_cancel_backend(pid) FROM pg_stat_activity
          WHERE query LIKE 'CREATE TABLE lookup_cycle_test%'"""
  )

const WaitingDdlQuery = """SELECT count(*) FROM pg_locks
     WHERE NOT granted AND relation = 'messages_lookup'::regclass"""

suite "Postgres driver - event loop blocking":
  var driver {.threadvar.}: PostgresDriver

  asyncSetup:
    let driverRes = await newTestPostgresDriver()
    if driverRes.isErr():
      assert false, driverRes.error

    driver = PostgresDriver(driverRes.get())

  asyncTeardown:
    (await driver.reset()).expect("driver to reset")
    (await driver.close()).expect("driver to close")

  asyncTest "first-time prepare behind a queued DDL does not block the event loop":
    ## Given a reader holding AccessShare on messages_lookup and a partition
    ## DDL queued for ACCESS EXCLUSIVE behind it
    let holder = openRaw()
    let ddl = openRaw()
    let observer = openRaw()
    defer:
      holder.close()
      ddl.close()
      observer.close()

    holder.exec(sql"BEGIN")
    discard holder.getValue(sql"SELECT count(*) FROM messages_lookup")

    check ddl.pqsendQuery(
      "CREATE TABLE lookup_freeze_test PARTITION OF messages_lookup FOR VALUES FROM (1) TO (2)"
    ) == 1
    check observer.pollUntil(WaitingDdlQuery)

    var releaser: Thread[ReleaseArgs]
    createThread(releaser, commitAfter, ReleaseArgs(conn: holder, delayMs: LockHoldMs))

    ## When the node writes, which prepares InsertRowMessagesLookup for the
    ## first time on this connection
    let probe = LoopProbe(running: true)
    let probeFut = probe.tick()

    let msg = fakeWakuMessage()
    let putRes = await driver.put(
      computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
    )

    probe.running = false
    await probeFut
    joinThread(releaser)
    ddl.drainResults()
    observer.exec(sql"DROP TABLE IF EXISTS lookup_freeze_test")

    echo "max event loop gap while the write was pending: ", $probe.maxGap

    ## Then the write succeeds and the loop kept running meanwhile
    check:
      putRes.isOk()
      probe.maxGap < MaxAcceptedLoopGap

  asyncTest "in-flight read plus queued DDL plus first-time prepare does not deadlock":
    ## Two pools on this event loop, like the driver's read and write pools.
    ## The write goes straight through runStmt: driver.put first runs the
    ## messages insert, whose await lets the loop drain the read and so hides
    ## the cycle. In production the loop was already frozen by an earlier
    ## prepare, so no such drain happened.
    let readPool =
      PgAsyncPool.new(storeMessageDbUrl, 1).expect("read pool to be created")
    let writePool =
      PgAsyncPool.new(storeMessageDbUrl, 1).expect("write pool to be created")
    let ddl = openRaw()
    let observer = openRaw()
    defer:
      ddl.close()
      observer.close()

    ## Open the read connection up front, so that the read below reaches the
    ## server before the blocking polls stop this loop
    (await readPool.pgQuery("SELECT 1")).expect("read pool to connect")

    ## Given a pooled read on messages_lookup whose result fills the socket
    ## buffers, so its backend holds AccessShare while blocked in ClientWrite
    let readFut = readPool.pgQuery(
      """SELECT (SELECT count(*) FROM messages_lookup), repeat('x', 1000)
         FROM generate_series(1, 50000)"""
    )
    check observer.pollUntil(
      """SELECT count(*) FROM pg_stat_activity
         WHERE query LIKE '%generate_series%' AND wait_event = 'ClientWrite'"""
    )

    ## and a partition DDL queued behind it
    check ddl.pqsendQuery(
      "CREATE TABLE lookup_cycle_test PARTITION OF messages_lookup FOR VALUES FROM (1) TO (2)"
    ) == 1
    check observer.pollUntil(WaitingDdlQuery)

    putDone.store(false)
    watchdogFired.store(false)
    var watchdog: Thread[int]
    createThread(watchdog, cancelDdlIfStuck, WatchdogTimeoutMs)

    ## When the write pool prepares the messages_lookup insert for the first time
    let msg = fakeWakuMessage()
    let hash = computeMessageHash(DefaultPubsubTopic, msg).to0xHex()
    let timestamp = $msg.timestamp
    let writeRes = await writePool.runStmt(
      "InsertRowMessagesLookup",
      "INSERT INTO messages_lookup (messageHash, timestamp) VALUES ($1, $2) ON CONFLICT DO NOTHING;",
      @[hash, timestamp],
      @[int32(hash.len), int32(timestamp.len)],
      @[int32(0), int32(0)],
    )

    putDone.store(true)
    joinThread(watchdog)
    let readRes = await readFut
    ddl.drainResults()
    observer.exec(sql"DROP TABLE IF EXISTS lookup_cycle_test")
    (await readPool.close()).expect("read pool to close")
    (await writePool.close()).expect("write pool to close")

    echo "watchdog had to break the lock cycle: ", watchdogFired.load()

    ## Then nothing waits on the frozen loop: the read, the DDL and the write
    ## all complete without the watchdog stepping in
    check:
      readRes.isOk()
      writeRes.isOk()
      not watchdogFired.load()
