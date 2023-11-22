{.used.}

import
  std/options,
  chronos,
  chronicles,
  libp2p/crypto/crypto

import
  ../../../waku/[
    node/peer_manager,
    waku_core,
    waku_archive,
    waku_archive/common,
    waku_archive/driver/sqlite_driver,
    common/databases/db_sqlite,
    waku_store
  ],
  ../testlib/[
    common,
    wakucore
  ]


proc newSqliteDatabase*(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()


proc newSqliteArchiveDriver*(): ArchiveDriver =
  let database = newSqliteDatabase()
  SqliteDriver.new(database).tryGet()


proc newWakuArchive*(driver: ArchiveDriver): WakuArchive =
  WakuArchive.new(driver).get()


proc computeArchiveCursor*(pubsubTopic: PubsubTopic, message: WakuMessage): ArchiveCursor =
  ArchiveCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: waku_archive.computeDigest(message)
  )


proc newArchiveDriverWithMessages*(pubsubTopic: PubSubTopic, msgList: seq[WakuMessage]): ArchiveDriver = 
  let driver = newSqliteArchiveDriver()

  for msg in msgList:
    let msgDigest = waku_archive.computeDigest(msg)
    discard waitFor driver.put(pubsubTopic, msg, msgDigest, msg.timestamp)

  return driver
