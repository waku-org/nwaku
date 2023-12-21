{.used.}

import
  std/[sequtils,times],
  stew/results,
  testutils/unittests,
  chronos,
  os
import
  ../../../waku/common/databases/db_sqlite,
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../../../waku/waku_archive,
    ../../../waku/waku_archive/driver/postgres_driver,
  ../../../waku/waku_archive/retention_policy,
  ../../../waku/waku_archive/retention_policy/retention_policy_capacity,
  ../../../waku/waku_archive/retention_policy/retention_policy_size,
  ../waku_archive/archive_utils,
  ../testlib/common,
  ../testlib/wakucore


const storeMessageDbUrl = "postgres://postgres:test123@localhost:5432/postgres"

proc newTestPostgresDriver(): ArchiveDriver =
  let driver = PostgresDriver.new(dbUrl = storeMessageDbUrl).tryGet()
  discard waitFor driver.reset()

  let initRes = waitFor driver.init()
  assert initRes.isOk(), initRes.error

  return driver


suite "Waku Archive - Retention policy":

  test "capacity retention policy - windowed message deletion":
    ## Given
    let
      capacity = 100
      excess = 60

    let driver = newTestPostgresDriver()

    let retentionPolicy: RetentionPolicy = CapacityRetentionPolicy.init(capacity=capacity)
    var putFutures = newSeq[Future[ArchiveDriverResult[void]]]()

    ## When
    for i in 1..capacity+excess:
      let msg = fakeWakuMessage(payload= @[byte i], contentTopic=DefaultContentTopic, ts=Timestamp(i))
      putFutures.add(driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp))
    
    discard waitFor allFinished(putFutures)

    require (waitFor retentionPolicy.execute(driver)).isOk()

    ## Then
    let numMessages = (waitFor driver.getMessagesCount()).tryGet()
    check:
      # Expected number of messages is 120 because
      # (capacity = 100) + (half of the overflow window = 15) + (5 messages added after after the last delete)
      # the window size changes when changing `const maxStoreOverflow = 1.3 in sqlite_store
      numMessages == 115

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")
  
  test "size retention policy - windowed message deletion":
    ## Given
    let driver = newTestPostgresDriver()
    let dbEngine = driver.getDbType()

    # make sure that the db is empty to before test begins
    let storedMsg = (waitFor driver.getAllMessages()).tryGet()
    # if there are messages in db, empty them
    if storedMsg.len > 0:
      let now = getNanosecondTime(getTime().toUnixFloat())
      require (waitFor driver.deleteMessagesOlderThanTimestamp(ts=now)).isOk()  
      require (waitFor driver.performVacuum()).isOk()

    # in bytes
    let sizeLimit:int64 = 10422851
    let excess = 800

    let retentionPolicy: RetentionPolicy = SizeRetentionPolicy.init(size=sizeLimit)
    var putFutures = newSeq[Future[ArchiveDriverResult[void]]]()

    ## When
    ##

    # create a number of messages so that the size of the DB overshoots
    for i in 1..excess:
        let msg = fakeWakuMessage(payload= @[byte (i*10)], contentTopic=DefaultContentTopic, ts=Timestamp(i))
        putFutures.add(driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp))

    # waitFor is used to synchronously wait for the futures to complete.
    discard waitFor allFinished(putFutures)

    ## Then
    # calculate the current database size
    var sizeDB = int64((waitFor driver.getDatabaseSize()).tryGet())

    if (sizeDB < sizeLimit):
      # we put a warning/debug that the size of the DB is less than the limit already
      echo ("WARNING: DB size is less than the limit. This test may not work as expected")

    require (waitFor retentionPolicy.execute(driver)).isOk()

    # get the updated DB size post vacuum
    sizeDB = int64((waitFor driver.getDatabaseSize()).tryGet())

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
      driver = newTestPostgresDriver()
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
      require (waitFor driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()
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

