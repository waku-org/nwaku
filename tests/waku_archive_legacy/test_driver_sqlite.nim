{.used.}

import std/sequtils, testutils/unittests, chronos
import
  waku/waku_archive_legacy,
  waku/waku_archive_legacy/driver/sqlite_driver,
  waku/waku_core,
  ../waku_archive_legacy/archive_utils,
  ../testlib/wakucore

suite "SQLite driver":
  test "init driver and database":
    ## Given
    let database = newSqliteDatabase()

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
    const meta = "test meta"

    let driver = newSqliteArchiveDriver()

    let msg = fakeWakuMessage(contentTopic = contentTopic, meta = meta)
    let msgHash = computeMessageHash(DefaultPubsubTopic, msg)

    ## When
    let putRes = waitFor driver.put(
      DefaultPubsubTopic, msg, computeDigest(msg), msgHash, msg.timestamp
    )

    ## Then
    check:
      putRes.isOk()

    let storedMsg = (waitFor driver.getAllMessages()).tryGet()
    check:
      storedMsg.len == 1
      storedMsg.all do(item: auto) -> bool:
        let (pubsubTopic, actualMsg, _, _, hash) = item
        actualMsg.contentTopic == contentTopic and pubsubTopic == DefaultPubsubTopic and
          hash == msgHash and msg.meta == actualMsg.meta

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")
