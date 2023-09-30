{.used.}

import
  std/sequtils,
  stew/results,
  testutils/unittests,
  chronos
import
  ../../../waku/common/databases/db_sqlite,
  ../../../waku/waku_core,
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/sqlite_driver,
  ../../../waku/waku_archive/retention_policy,
  ../../../waku/waku_archive/retention_policy/retention_policy_capacity,
  ../../../waku/waku_archive/retention_policy/retention_policy_size,
  ../testlib/common,
  ../testlib/wakucore


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()

proc newTestArchiveDriver(): ArchiveDriver =
  let db = newTestDatabase()
  SqliteDriver.new(db).tryGet()


suite "Waku Archive - Retention policy":

  test "capacity retention policy - windowed message deletion":
    ## Given
    let
      capacity = 100
      excess = 65

    let driver = newTestArchiveDriver()

    let retentionPolicy: RetentionPolicy = CapacityRetentionPolicy.init(capacity=capacity)

    ## When
    for i in 1..capacity+excess:
      let msg = fakeWakuMessage(payload= @[byte i], contentTopic=DefaultContentTopic, ts=Timestamp(i))

      require (waitFor driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp)).isOk()
      require (waitFor retentionPolicy.execute(driver)).isOk()

    ## Then
    let numMessages = (waitFor driver.getMessagesCount()).tryGet()
    check:
      # Expected number of messages is 120 because
      # (capacity = 100) + (half of the overflow window = 15) + (5 messages added after after the last delete)
      # the window size changes when changing `const maxStoreOverflow = 1.3 in sqlite_store
      numMessages == 120

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")
  
  test "size retention policy - windowed message deletion":
    ## Given
    let
      # in megabytes
      sizeLimit:float = 0.05
      excess = 123

    let driver = newTestArchiveDriver()

    let retentionPolicy: RetentionPolicy = SizeRetentionPolicy.init(size=sizeLimit)

    ## When

    var putFutures = newSeq[Future[ArchiveDriverResult[void]]]()
    var retentionFutures = newSeq[Future[ArchiveDriverResult[void]]]()

    for i in 1..excess:
        let msg = fakeWakuMessage(payload= @[byte i], contentTopic=DefaultContentTopic, ts=Timestamp(i))
        putFutures.add(driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp))
        retentionFutures.add(retentionPolicy.execute(driver))

    # waitFor is used to synchronously wait for the futures to complete.
    discard waitFor allFinished(putFutures & retentionFutures)
            
    ## Then
    # calculate the current database size
    let pageSize = (waitFor driver.getPagesSize()).tryGet()
    let pageCount = (waitFor driver.getPagesCount()).tryGet()
    let sizeDB = float(pageCount * pageSize) / (1024.0 * 1024.0)

    check:
      # size of the database is used to check if the storage limit has been preserved
      # check the current database size with the limitSize provided by the user
      # it should be lower 
      sizeDB <= sizeLimit

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")

  test "store capacity should be limited":
    ## Given
    const capacity = 5
    const contentTopic = "test-content-topic"

    let
      driver = newTestArchiveDriver()
      retentionPolicy: RetentionPolicy = CapacityRetentionPolicy.init(capacity=capacity)

    let messages = @[
      fakeWakuMessage(contentTopic=DefaultContentTopic, ts=ts(0)),
      fakeWakuMessage(contentTopic=DefaultContentTopic, ts=ts(1)),

      fakeWakuMessage(contentTopic=contentTopic, ts=ts(2)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(3)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(4)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(5)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(6))
    ]

    ## When
    for msg in messages:
      require (waitFor driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp)).isOk()
      require (waitFor retentionPolicy.execute(driver)).isOk()

    ## Then
    let storedMsg = (waitFor driver.getAllMessages()).tryGet()
    check:
      storedMsg.len == capacity
      storedMsg.all do (item: auto) -> bool:
        let (pubsubTopic, msg, digest, storeTimestamp) = item
        msg.contentTopic == contentTopic and
        pubsubTopic == DefaultPubsubTopic

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")
