{.used.}

import std/options, results, chronos, libp2p/crypto/crypto

import
  waku/[
    node/peer_manager,
    waku_core,
    waku_archive_legacy,
    waku_archive_legacy/common,
    waku_archive_legacy/driver/sqlite_driver,
    waku_archive_legacy/driver/sqlite_driver/migrations,
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

proc computeArchiveCursor*(
    pubsubTopic: PubsubTopic, message: WakuMessage
): ArchiveCursor =
  ArchiveCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: computeDigest(message),
    hash: computeMessageHash(pubsubTopic, message),
  )

proc put*(
    driver: ArchiveDriver, pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]
): ArchiveDriver =
  for msg in msgList:
    let
      msgDigest = computeDigest(msg)
      msgHash = computeMessageHash(pubsubTopic, msg)
      _ = waitFor driver.put(pubsubTopic, msg, msgDigest, msgHash, msg.timestamp)
        # discard crashes
  return driver

proc newArchiveDriverWithMessages*(
    pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]
): ArchiveDriver =
  var driver = newSqliteArchiveDriver()
  driver = driver.put(pubsubTopic, msgList)
  return driver
