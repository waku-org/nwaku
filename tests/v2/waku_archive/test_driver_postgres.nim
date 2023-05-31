{.used.}

import
  std/[sequtils,times,options],
  testutils/unittests,
  chronos
import
  ../../../waku/v2/waku_archive,
  ../../../waku/v2/waku_archive/driver/postgres_driver,
  ../../../waku/v2/waku_core,
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
    #TODO: make the test asynchronous
    return

    ## When
    let driverRes = PostgresDriver.new(storeMessageDbUrl)

    ## Then
    require:
      driverRes.isOk()

    let driver: ArchiveDriver = driverRes.tryGet()
    require:
      not driver.isNil()

    let beforeSleep = now()
    for _ in 1 .. 20:
      discard (PostgresDriver driver).sleep(1)

    require (now() - beforeSleep) < 20

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "init driver and database":

    ## When
    let driverRes = PostgresDriver.new(storeMessageDbUrl)

    ## Then
    require:
      driverRes.isOk()

    let driver: ArchiveDriver = driverRes.tryGet()
    require:
      not driver.isNil()

    discard driverRes.get().reset()
    let initRes = driverRes.get().init()

    require:
      initRes.isOk()

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "insert a message":
    ## Given
    const contentTopic = "test-content-topic"

    let driverRes = PostgresDriver.new(storeMessageDbUrl)

    require:
      driverRes.isOk()

    discard driverRes.get().reset()
    discard driverRes.get().init()

    let driver: ArchiveDriver = driverRes.tryGet()
    require:
      not driver.isNil()

    let msg = fakeWakuMessage(contentTopic=contentTopic)

    let computedDigest = computeDigest(msg)
    ## When
    let putRes = await driver.put(DefaultPubsubTopic, msg, computedDigest, msg.timestamp)

    ## Then
    require:
      putRes.isOk()

    let storedMsg = (await driver.getAllMessages()).tryGet()
    require:
      storedMsg.len == 1
      storedMsg.all do (item: auto) -> bool:
        let (pubsubTopic, actualMsg, digest, storeTimestamp) = item
        actualMsg.contentTopic == contentTopic and
        pubsubTopic == DefaultPubsubTopic and
        toHex(computedDigest.data) == toHex(digest) and
        toHex(actualMsg.payload) == toHex(msg.payload)

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "insert and query message":
    ## Given
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const pubsubTopic1 = "pubsubtopic-1"
    const pubsubTopic2 = "pubsubtopic-2"

    let driverRes = PostgresDriver.new(storeMessageDbUrl)

    require:
      driverRes.isOk()

    discard driverRes.get().reset()
    discard driverRes.get().init()

    let driver: ArchiveDriver = driverRes.tryGet()
    require:
      not driver.isNil()

    let msg1 = fakeWakuMessage(contentTopic=contentTopic1)

    ## When
    var putRes = await driver.put(pubsubTopic1, msg1, computeDigest(msg1), msg1.timestamp)

    ## Then
    require:
      putRes.isOk()

    let msg2 = fakeWakuMessage(contentTopic=contentTopic2)

    ## When
    putRes = await driver.put(pubsubTopic2, msg2, computeDigest(msg2), msg2.timestamp)

    ## Then
    require:
      putRes.isOk()

    let countMessagesRes = await driver.getMessagesCount()

    require:
      countMessagesRes.isOk() and
        countMessagesRes.get() == 2

    var messagesRes = await driver.getMessages(contentTopic = @[contentTopic1])

    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1

    # Get both content topics, check ordering
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2])
    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 2 and
      messagesRes.get()[0][1].WakuMessage.contentTopic == contentTopic1

    # Descending order
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           ascendingOrder = false)
    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 2 and
      messagesRes.get()[0][1].WakuMessage.contentTopic == contentTopic2

    # cursor
    # Get both content topics
    messagesRes =
        await driver.getMessages(contentTopic = @[contentTopic1,
                                                  contentTopic2],
                                 cursor = some(
                                        computeTestCursor(pubsubTopic1,
                                                          messagesRes.get()[0][1])))
    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1

    # Get both content topics but one pubsub topic
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           pubsubTopic = some(pubsubTopic1))
    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1 and
      messagesRes.get()[0][1].WakuMessage.contentTopic == contentTopic1

    # Limit
    messagesRes = await driver.getMessages(contentTopic = @[contentTopic1,
                                                            contentTopic2],
                                           maxPageSize = 1)
    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "insert true duplicated messages":
    # Validates that two completely equal messages can not be stored.
    ## Given
    let driverRes = PostgresDriver.new(storeMessageDbUrl)

    require:
      driverRes.isOk()

    discard driverRes.get().reset()
    discard driverRes.get().init()

    let driver: ArchiveDriver = driverRes.tryGet()
    require:
      not driver.isNil()

    let now = now()

    let msg1 = fakeWakuMessage(ts = now)
    let msg2 = fakeWakuMessage(ts = now)

    var putRes = await driver.put(DefaultPubsubTopic,
                                  msg1, computeDigest(msg1), msg1.timestamp)
    ## Then
    require:
      putRes.isOk()

    putRes = await driver.put(DefaultPubsubTopic,
                              msg2, computeDigest(msg2), msg2.timestamp)
    ## Then
    require:
      not putRes.isOk()


