{.used.}

import
  std/[sequtils,times,options],
  testutils/unittests,
  chronos
import
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver/postgres_driver,
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../testlib/wakucore

proc now():int64 = getTime().toUnix()

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

  const storeMessageDbUrl = "postgres://postgres:test123@localhost:5432/postgres"

  asyncTest "Asynchronous queries":
    let driverRes = PostgresDriver.new(dbUrl = storeMessageDbUrl,
                                       maxConnections = 100)

    assert driverRes.isOk(), driverRes.error

    let driver = driverRes.value
    discard await driver.reset()

    var futures = newSeq[Future[ArchiveDriverResult[void]]](0)

    let beforeSleep = now()
    for _ in 1 .. 100:
      futures.add(driver.sleep(1))

    await allFutures(futures)

    let diff = now() - beforeSleep
    # Actually, the diff randomly goes between 1 and 2 seconds.
    # although in theory it should spend 1s because we establish 100
    # connections and we spawn 100 tasks that spend ~1s each.
    require diff < 20

    (await driver.close()).expect("driver to close")

  asyncTest "Init database":
    let driverRes = PostgresDriver.new(storeMessageDbUrl)
    assert driverRes.isOk(), driverRes.error

    let driver = driverRes.value
    discard await driver.reset()

    let initRes = await driver.init()
    assert initRes.isOk(), initRes.error

    (await driver.close()).expect("driver to close")

  asyncTest "Insert a message":
    const contentTopic = "test-content-topic"

    let driverRes = PostgresDriver.new(storeMessageDbUrl)
    assert driverRes.isOk(), driverRes.error

    let driver = driverRes.get()

    discard await driver.reset()

    let initRes = await driver.init()
    assert initRes.isOk(), initRes.error

    let msg = fakeWakuMessage(contentTopic=contentTopic)

    let computedDigest = computeDigest(msg)

    let putRes = await driver.put(DefaultPubsubTopic, msg, computedDigest, computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)
    assert putRes.isOk(), putRes.error

    let storedMsg = (await driver.getAllMessages()).tryGet()
    require:
      storedMsg.len == 1
      storedMsg.all do (item: auto) -> bool:
        let (pubsubTopic, actualMsg, digest, storeTimestamp) = item
        actualMsg.contentTopic == contentTopic and
        pubsubTopic == DefaultPubsubTopic and
        toHex(computedDigest.data) == toHex(digest) and
        toHex(actualMsg.payload) == toHex(msg.payload)

    (await driver.close()).expect("driver to close")

  asyncTest "Insert and query message":
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const pubsubTopic1 = "pubsubtopic-1"
    const pubsubTopic2 = "pubsubtopic-2"

    let driverRes = PostgresDriver.new(storeMessageDbUrl)
    assert driverRes.isOk(), driverRes.error

    let driver = driverRes.value

    discard await driver.reset()

    let initRes = await driver.init()
    assert initRes.isOk(), initRes.error

    let msg1 = fakeWakuMessage(contentTopic=contentTopic1)

    var putRes = await driver.put(pubsubTopic1, msg1, computeDigest(msg1), computeMessageHash(pubsubTopic1, msg1), msg1.timestamp)
    assert putRes.isOk(), putRes.error

    let msg2 = fakeWakuMessage(contentTopic=contentTopic2)

    putRes = await driver.put(pubsubTopic2, msg2, computeDigest(msg2), computeMessageHash(pubsubTopic2, msg2), msg2.timestamp)
    assert putRes.isOk(), putRes.error

    let countMessagesRes = await driver.getMessagesCount()

    require countMessagesRes.isOk() and countMessagesRes.get() == 2

    var messagesRes = await driver.getMessages(contentTopic = @[contentTopic1])

    require messagesRes.isOk()
    require messagesRes.get().len == 1

    # Get both content topics, check ordering
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2])
    assert messagesRes.isOk(), messagesRes.error

    require:
      messagesRes.get().len == 2 and
      messagesRes.get()[0][1].contentTopic == contentTopic1

    # Descending order
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           ascendingOrder = false)
    assert messagesRes.isOk(), messagesRes.error

    require:
      messagesRes.get().len == 2 and
      messagesRes.get()[0][1].contentTopic == contentTopic2

    # cursor
    # Get both content topics
    messagesRes =
        await driver.getMessages(contentTopic = @[contentTopic1,
                                                  contentTopic2],
                                 cursor = some(
                                        computeTestCursor(pubsubTopic1,
                                                          messagesRes.get()[1][1])))
    require messagesRes.isOk()
    require messagesRes.get().len == 1

    # Get both content topics but one pubsub topic
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           pubsubTopic = some(pubsubTopic1))
    assert messagesRes.isOk(), messagesRes.error

    require:
      messagesRes.get().len == 1 and
      messagesRes.get()[0][1].contentTopic == contentTopic1

    # Limit
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           maxPageSize = 1)
    assert messagesRes.isOk(), messagesRes.error
    require messagesRes.get().len == 1

    (await driver.close()).expect("driver to close")

  asyncTest "Insert true duplicated messages":
    # Validates that two completely equal messages can not be stored.
    let driverRes = PostgresDriver.new(storeMessageDbUrl)
    assert driverRes.isOk(), driverRes.error

    let driver = driverRes.value

    discard await driver.reset()

    let initRes = await driver.init()
    assert initRes.isOk(), initRes.error

    let now = now()

    let msg1 = fakeWakuMessage(ts = now)
    let msg2 = fakeWakuMessage(ts = now)

    var putRes = await driver.put(DefaultPubsubTopic,
                                  msg1, computeDigest(msg1), computeMessageHash(DefaultPubsubTopic, msg1), msg1.timestamp)
    assert putRes.isOk(), putRes.error

    putRes = await driver.put(DefaultPubsubTopic,
                              msg2, computeDigest(msg2), computeMessageHash(DefaultPubsubTopic, msg2), msg2.timestamp)
    require not putRes.isOk()

    (await driver.close()).expect("driver to close")
