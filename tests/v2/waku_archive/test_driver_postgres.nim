{.used.}

import
  std/sequtils,
  testutils/unittests,
  chronos
import
  ../../../waku/v2/protocol/waku_archive,
  ../../../waku/v2/config,
  ../../../waku/v2/protocol/waku_archive/driver/postgres_driver,
  ../../../waku/v2/protocol/waku_message,
  ../testlib/common,
  ../testlib/waku2

proc defaultConf : WakuNodeConf =
  return WakuNodeConf(
    storeMessageDbUrl: "postgres://postgres:test123@localhost:5432/postgres",
    listenAddress: ValidIpAddress.init("127.0.0.1"), rpcAddress: ValidIpAddress.init("127.0.0.1"), restAddress: ValidIpAddress.init("127.0.0.1"), metricsServerAddress: ValidIpAddress.init("127.0.0.1"))

suite "Postgres driver":

  test "init driver and database":

    ## When
    let driverRes = PostgresDriver.new(defaultConf())

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
    driver.close().expect("driver to close")

  test "insert a message":
    ## Given
    const contentTopic = "test-content-topic"

    let driverRes = PostgresDriver.new(defaultConf())

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
    let putRes = driver.put(DefaultPubsubTopic, msg, computedDigest, msg.timestamp)

    ## Then
    require:
      putRes.isOk()

    let storedMsg = driver.getAllMessages().tryGet()
    require:
      storedMsg.len == 1
      storedMsg.all do (item: auto) -> bool:
        let (pubsubTopic, actualMsg, digest, storeTimestamp) = item
        actualMsg.contentTopic == contentTopic and
        pubsubTopic == DefaultPubsubTopic and
        toHex(computedDigest.data) == toHex(digest) and
        toHex(actualMsg.payload) == toHex(msg.payload)

    ## Cleanup
    driver.close().expect("driver to close")

  test "insert and query message":
    ## Given
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const pubsubTopic1 = "pubsubtopic-1"
    const pubsubTopic2 = "pubsubtopic-2"

    let driverRes = PostgresDriver.new(defaultConf())

    require:
      driverRes.isOk()

    discard driverRes.get().reset()
    discard driverRes.get().init()

    let driver: ArchiveDriver = driverRes.tryGet()
    require:
      not driver.isNil()

    let msg1 = fakeWakuMessage(contentTopic=contentTopic1)

    ## When
    var putRes = driver.put(pubsubTopic1, msg1, computeDigest(msg1), msg1.timestamp)

    ## Then
    require:
      putRes.isOk()

    let msg2 = fakeWakuMessage(contentTopic=contentTopic2)

    ## When
    putRes = driver.put(pubsubTopic2, msg2, computeDigest(msg2), msg2.timestamp)

    ## Then
    require:
      putRes.isOk()

    let countMessagesRes = driver.getMessagesCount()

    require:
      countMessagesRes.isOk() and
        countMessagesRes.get() == 2

    var messagesRes = driver.getMessages(contentTopic = @[contentTopic1])

    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1

    # Get both content topics, check ordering
    messagesRes = driver.getMessages(contentTopic = @[contentTopic1, contentTopic2])

    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 2 and messagesRes.get()[0][1].WakuMessage.contentTopic == contentTopic1

    # Descending order
    messagesRes = driver.getMessages(contentTopic = @[contentTopic1, contentTopic2], ascendingOrder = false)

    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 2 and messagesRes.get()[0][1].WakuMessage.contentTopic == contentTopic2

    # cursor

    let cursor = ArchiveCursor(storeTime: messagesRes.get()[0][3])
    # Get both content topics
    messagesRes = driver.getMessages(contentTopic = @[contentTopic1, contentTopic2],cursor =  some(cursor))

    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1

    # Get both content topics but one pubsub topic
    messagesRes = driver.getMessages(contentTopic = @[contentTopic1, contentTopic2], pubsubTopic = some(pubsubTopic1))

    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1 and messagesRes.get()[0][1].WakuMessage.contentTopic == contentTopic1

    # Limit
    messagesRes = driver.getMessages(contentTopic = @[contentTopic1, contentTopic2], maxPageSize = 1)

    require:
      messagesRes.isOk()

    require:
      messagesRes.get().len == 1

    ## Cleanup
    driver.close().expect("driver to close")
