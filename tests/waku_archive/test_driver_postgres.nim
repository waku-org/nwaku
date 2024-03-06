{.used.}

import
  std/[sequtils,options],
  testutils/unittests,
  chronos
import
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/postgres_driver,
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../testlib/wakucore,
  ../testlib/testasync,
  ../testlib/postgres

proc computeTestCursor(pubsubTopic: PubsubTopic,
                       message: WakuMessage):
                       ArchiveCursor =
  ArchiveCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: computeDigest(message)
  )

suite "Postgres driver":
  ## Unique driver instance
  var driver {.threadvar.}: PostgresDriver

  asyncSetup:
    let driverRes = await newTestPostgresDriver()
    if driverRes.isErr():
      assert false, driverRes.error

    driver = PostgresDriver(driverRes.get())

  asyncTeardown:
    let resetRes = await driver.reset()
    if resetRes.isErr():
      assert false, resetRes.error

    (await driver.close()).expect("driver to close")

  asyncTest "Asynchronous queries":
    var futures = newSeq[Future[ArchiveDriverResult[void]]](0)

    let beforeSleep = now()
    for _ in 1 .. 100:
      futures.add(driver.sleep(1))

    await allFutures(futures)

    let diff = now() - beforeSleep
    # Actually, the diff randomly goes between 1 and 2 seconds.
    # although in theory it should spend 1s because we establish 100
    # connections and we spawn 100 tasks that spend ~1s each.
    assert diff < 20_000_000_000

  asyncTest "Insert a message":
    const contentTopic = "test-content-topic"

    let msg = fakeWakuMessage(contentTopic=contentTopic)

    let computedDigest = computeDigest(msg)

    let putRes = await driver.put(DefaultPubsubTopic, msg, computedDigest, computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)
    assert putRes.isOk(), putRes.error

    let storedMsg = (await driver.getAllMessages()).tryGet()

    assert storedMsg.len == 1

    let (pubsubTopic, actualMsg, digest, storeTimestamp) = storedMsg[0]
    assert actualMsg.contentTopic == contentTopic
    assert pubsubTopic == DefaultPubsubTopic
    assert toHex(computedDigest.data) == toHex(digest)
    assert toHex(actualMsg.payload) == toHex(msg.payload)

  asyncTest "Insert and query message":
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const pubsubTopic1 = "pubsubtopic-1"
    const pubsubTopic2 = "pubsubtopic-2"

    let msg1 = fakeWakuMessage(contentTopic=contentTopic1)

    var putRes = await driver.put(pubsubTopic1, msg1, computeDigest(msg1), computeMessageHash(pubsubTopic1, msg1), msg1.timestamp)
    assert putRes.isOk(), putRes.error

    let msg2 = fakeWakuMessage(contentTopic=contentTopic2)

    putRes = await driver.put(pubsubTopic2, msg2, computeDigest(msg2), computeMessageHash(pubsubTopic2, msg2), msg2.timestamp)
    assert putRes.isOk(), putRes.error

    let countMessagesRes = await driver.getMessagesCount()

    assert countMessagesRes.isOk(), $countMessagesRes.error
    assert countMessagesRes.get() == 2

    var messagesRes = await driver.getMessages(contentTopic = @[contentTopic1])

    assert messagesRes.isOk(), $messagesRes.error
    assert messagesRes.get().len == 1

    # Get both content topics, check ordering
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2])
    assert messagesRes.isOk(), messagesRes.error

    assert messagesRes.get().len == 2
    assert messagesRes.get()[0][1].contentTopic == contentTopic1

    # Descending order
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           ascendingOrder = false)
    assert messagesRes.isOk(), messagesRes.error

    assert messagesRes.get().len == 2
    assert messagesRes.get()[0][1].contentTopic == contentTopic2

    # cursor
    # Get both content topics
    messagesRes =
        await driver.getMessages(contentTopic = @[contentTopic1,
                                                  contentTopic2],
                                 cursor = some(
                                        computeTestCursor(pubsubTopic1,
                                                          messagesRes.get()[1][1])))
    assert messagesRes.isOk()
    assert messagesRes.get().len == 1

    # Get both content topics but one pubsub topic
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           pubsubTopic = some(pubsubTopic1))
    assert messagesRes.isOk(), messagesRes.error

    assert messagesRes.get().len == 1
    assert messagesRes.get()[0][1].contentTopic == contentTopic1

    # Limit
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           maxPageSize = 1)
    assert messagesRes.isOk(), messagesRes.error
    assert messagesRes.get().len == 1

  asyncTest "Insert true duplicated messages":
    # Validates that two completely equal messages can not be stored.

    let now = now()

    let msg1 = fakeWakuMessage(ts = now)
    let msg2 = fakeWakuMessage(ts = now)

    var putRes = await driver.put(DefaultPubsubTopic,
                                  msg1, computeDigest(msg1), computeMessageHash(DefaultPubsubTopic, msg1), msg1.timestamp)
    assert putRes.isOk(), putRes.error

    putRes = await driver.put(DefaultPubsubTopic,
                              msg2, computeDigest(msg2), computeMessageHash(DefaultPubsubTopic, msg2), msg2.timestamp)
    assert not putRes.isOk()

