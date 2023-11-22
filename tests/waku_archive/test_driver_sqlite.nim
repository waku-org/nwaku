{.used.}

import
  std/sequtils,
  testutils/unittests,
  chronos
import
  ../../../waku/common/databases/db_sqlite,
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/sqlite_driver,
  ../../../waku/waku_core,
  ../testlib/common,
  ../testlib/wakucore


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()

proc newTestSqliteDriver(): ArchiveDriver =
  let db = newTestDatabase()
  SqliteDriver.new(db).tryGet()


suite "SQLite driver":

  test "init driver and database":
    ## Given
    let database = newTestDatabase()

    ## When
    let driverRes = SqliteDriver.new(database)

    ## Then
    check:
      driverRes.isOk()

    let driver: ArchiveDriver = driverRes.tryGet()
    check:
      not driver.isNil()

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")

  test "insert a message":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let msg = fakeWakuMessage(contentTopic=contentTopic)

    ## When
    let putRes = waitFor driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)

    ## Then
    check:
      putRes.isOk()

    let storedMsg = (waitFor driver.getAllMessages()).tryGet()
    check:
      storedMsg.len == 1
      storedMsg.all do (item: auto) -> bool:
        let (pubsubTopic, msg, digest, storeTimestamp) = item
        msg.contentTopic == contentTopic and
        pubsubTopic == DefaultPubsubTopic

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")
