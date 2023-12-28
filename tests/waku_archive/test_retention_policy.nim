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
      # Expected number of messages is 115 because
      # (capacity = 100) + (half of the overflow window = 15)
      numMessages == 115

    ## Cleanup
    (waitFor driver.close()).expect("driver to close")
  
  test "size retention policy - windowed message deletion":
    ## Given
    let driver = newTestPostgresDriver()

    # make sure that the db is empty to before test begins
    let storedMsg = (waitFor driver.getAllMessages()).tryGet()
    # if there are messages in db, delete them before the test begins
    if storedMsg.len > 0:
      let now = getNanosecondTime(getTime().toUnixFloat())
      require (waitFor driver.deleteMessagesOlderThanTimestamp(ts=now)).isOk()  
      require (waitFor driver.performVacuum()).isOk()

    # get the minimum/empty size of the database
    let sizeLimit = int64((waitFor driver.getDatabaseSize()).tryGet())
    let num_messages = 100
    let retryLimit = 4

    let retentionPolicy: RetentionPolicy = SizeRetentionPolicy.init(size=sizeLimit)
    var putFutures = newSeq[Future[ArchiveDriverResult[void]]]()

    ## When
    # create a number of messages to increase DB size
    for i in 1..num_messages:
      let msg = fakeWakuMessage(payload= @[byte i], contentTopic=DefaultContentTopic, ts=Timestamp(i))
      putFutures.add(driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp))

    # waitFor is used to synchronously wait for the futures to complete.
    discard waitFor allFinished(putFutures)
    sleep(150)

    ## Then
    # calculate the current database size
    let sizeBeforeRetPolicy = int64((waitFor driver.getDatabaseSize()).tryGet())
    var sizeAfterRetPolicy:int64 = sizeBeforeRetPolicy
    var retryCounter = 0

    while (sizeAfterRetPolicy >= sizeBeforeRetPolicy)  and (retryCounter < retryLimit):
      # execute the retention policy
      require (waitFor retentionPolicy.execute(driver)).isOk()

      # get the updated DB size post vacuum
      sizeAfterRetPolicy = int64((waitFor driver.getDatabaseSize()).tryGet())
      retryCounter += 1
      sleep(150)

    check:
      # check if the size of the database has been reduced after executing the retention policy
      sizeAfterRetPolicy < sizeBeforeRetPolicy

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

