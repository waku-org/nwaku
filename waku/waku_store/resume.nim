import sqlite3_abi, results, chronicles, chronos, metrics

import ../common/databases/db_sqlite, ../waku_core

const
  OnlineDbUrl = "lastonline.db"
  DefaultLastOnlineInterval = chronos.minutes(1)

type StoreResume* = ref object
  interval: timer.Duration
  handle: Future[void]
  db: SqliteDatabase
  replaceStmt: SqliteStmt[(Timestamp), void]

proc setupLastOnlineDB(): Result[SqliteDatabase, string] =
  let db = SqliteDatabase.new(OnlineDbUrl).valueOr:
    return err($error)

  let createStmt = db
    .prepareStmt(
      """CREATE TABLE IF NOT EXISTS last_online (timestamp BIGINT NOT NULL);""",
      NoParams, void,
    )
    .expect("Valid statement")

  createStmt.exec(()).isOkOr:
    return err("failed to exec stmt")

  # We dispose of this prepared statement here, as we never use it again
  createStmt.dispose()

  return ok(db)

proc new*(
    T: type StoreResume, interval = DefaultLastOnlineInterval
): Result[T, string] =
  let db = setupLastOnlineDB().valueOr:
    return err("Failed to setup last online DB")

  let replaceStmt = db
    .prepareStmt("REPLACE INTO last_online (timestamp) VALUES (?);", (Timestamp), void)
    .expect("Valid statement")

  let resume = StoreResume(interval: interval, db: db, replaceStmt: replaceStmt)

  return ok(resume)

proc getLastOnlineTimestamp*(self: StoreResume): Result[Timestamp, string] =
  var timestamp: Timestamp

  proc queryCallback(s: ptr sqlite3_stmt) =
    timestamp = sqlite3_column_int64(s, 0)

  self.db.query("SELECT MAX(timestamp) FROM last_online", queryCallback).isOkOr:
    return err("failed to query last online timestamp: " & $error)

  return ok(timestamp)

proc setLastOnlineTimestamp*(self: StoreResume, timestamp: Timestamp): Result[void, string] =
  self.replaceStmt.exec((timestamp)).isOkOr:
    return err("Failed to execute replace stmt" & $error)

  return ok()

proc periodicSetLastOnline(self: StoreResume) {.async.} =
  ## Save a timestamp periodically
  ## so that a node can know when it was last online
  while true:
    let ts = getNowInNanosecondTime()

    self.setLastOnlineTimestamp(ts).isOkOr:
      error "Failed to set last online timestamp", error, time = ts

    await sleepAsync(self.interval)

proc start*(self: StoreResume) =
  self.handle = self.periodicSetLastOnline()

proc stopWait*(self: StoreResume) {.async.} =
  if not self.handle.isNil():
    await noCancel(self.handle.cancelAndWait())

  self.replaceStmt.dispose()
  self.db.close()
