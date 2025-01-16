{.used.}

import std/options, stew/results, chronos, libp2p/crypto/crypto

import
  waku/[
    node/peer_manager,
    waku_core,
    waku_archive,
    waku_archive/common,
    waku_archive/driver/sqlite_driver,
    waku_archive/driver/sqlite_driver/migrations,
    common/databases/db_sqlite,
  ],
  ../testlib/[wakucore]

proc newSqliteDatabase*(path: Option[string] = string.none()): SqliteDatabase =
  SqliteDatabase.new(path.get(":memory:")).tryGet()

proc newSqliteArchiveDriver*(): ArchiveDriver =
  let database = newSqliteDatabase()
  migrate(database).tryGet()
  return SqliteDriver.new(database).tryGet()

proc newWakuArchive*(driver: ArchiveDriver): WakuArchive =
  WakuArchive.new(driver).get()

proc put*(
    driver: ArchiveDriver, pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]
): ArchiveDriver =
  for msg in msgList:
    let _ = waitFor driver.put(computeMessageHash(pubsubTopic, msg), pubsubTopic, msg)
  return driver

proc newArchiveDriverWithMessages*(
    pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]
): ArchiveDriver =
  var driver = newSqliteArchiveDriver()
  driver = driver.put(pubsubTopic, msgList)
  return driver
