{.used.}

import
  std/[options, sequtils],
  testutils/unittests,
  chronos
import
  ../../../waku/common/sqlite,
  ../../../waku/v2/protocol/waku_archive,
  ../../../waku/v2/protocol/waku_archive/driver/sqlite_driver,
  ../../../waku/v2/protocol/waku_message,
  ../utils,
  ../testlib/common


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()

proc newTestSqliteDriver(): ArchiveDriver =
  let db = newTestDatabase()
  SqliteDriver.new(db).tryGet()

proc computeTestCursor(pubsubTopic: PubsubTopic, message: WakuMessage): ArchiveCursor =
  ArchiveCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: computeDigest(message)
  )


suite "SQLite driver - query by content topic":

  test "no content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=DefaultContentTopic, ts=ts(00)),
      fakeWakuMessage(@[byte 1], contentTopic=DefaultContentTopic, ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)),

      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      maxPageSize=5,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 5
      filteredMessages == messages[0..4]

    ## Cleanup
    driver.close().expect("driver to close")

  test "single content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(ts=ts(00)),
      fakeWakuMessage(ts=ts(10)),

      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),

      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == messages[2..3]

    ## Cleanup
    driver.close().expect("driver to close")

  test "single content topic - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(ts=ts(00)),
      fakeWakuMessage(ts=ts(10)),

      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(40)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(50)),

      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      maxPageSize=2,
      ascendingOrder=false
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == messages[6..7]

    ## Cleanup
    driver.close().expect("driver to close")

  test "multiple content topic":
    ## Given
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const contentTopic3 = "test-content-topic-3"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(ts=ts(00)),
      fakeWakuMessage(ts=ts(10)),

      fakeWakuMessage(@[byte 1], contentTopic=contentTopic1, ts=ts(20)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic2, ts=ts(30)),

      fakeWakuMessage(@[byte 3], contentTopic=contentTopic3, ts=ts(40)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic1, ts=ts(50)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic2, ts=ts(60)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic3, ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic1, contentTopic2],
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == messages[2..3]

    ## Cleanup
    driver.close().expect("driver to close")

  test "single content topic - no results":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(@[byte 1], contentTopic=DefaultContentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 2], contentTopic=DefaultContentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 3], contentTopic=DefaultContentTopic, ts=ts(40)),
      fakeWakuMessage(@[byte 4], contentTopic=DefaultContentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 5], contentTopic=DefaultContentTopic, ts=ts(60)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 0

    ## Cleanup
    driver.close().expect("driver to close")

  test "content topic and max page size - not enough messages stored":
    ## Given
    const pageSize: uint = 50

    let driver = newTestSqliteDriver()

    for t in 0..<40:
      let msg = fakeWakuMessage(@[byte t], DefaultContentTopic, ts=ts(t))
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[DefaultContentTopic],
      maxPageSize=pageSize,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 40

    ## Cleanup
    driver.close().expect("driver to close")


suite "SQLite driver - query by pubsub topic":

  test "pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30))),

      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50))),
      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      pubsubTopic=some(pubsubTopic),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[4..5]

    ## Cleanup
    driver.close().expect("driver to close")

  test "no pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10))),

      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30))),
      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50))),
      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[0..1]

    ## Cleanup
    driver.close().expect("driver to close")

  test "content topic and pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30))),

      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50))),

      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70))),
    ]
    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[4..5]

    ## Cleanup
    driver.close().expect("driver to close")


suite "SQLite driver - query by cursor":

  test "only cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)), # << cursor

      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),

      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, messages[4])

    ## When
    let res = driver.getMessages(
      cursor=some(cursor),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == messages[5..6]

    ## Cleanup
    driver.close().expect("driver to close")

  test "only cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),

      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),

      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)), # << cursor
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, messages[4])

    ## When
    let res = driver.getMessages(
      cursor=some(cursor),
      maxPageSize=2,
      ascendingOrder=false
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == messages[2..3]

    ## Cleanup
    driver.close().expect("driver to close")

  test "content topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)), # << cursor
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, messages[4])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == messages[5..6]

    ## Cleanup
    driver.close().expect("driver to close")

  test "content topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let messages = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)), # << cursor
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, messages[6])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=false
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 4
      filteredMessages == messages[2..5]

    ## Cleanup
    driver.close().expect("driver to close")

  test "pubsub topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin))),
      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin))), # << cursor

      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70, timeOrigin))),

      (DefaultPubsubTopic, fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(messages[5][0], messages[5][1])

    ## When
    let res = driver.getMessages(
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[6..7]

    ## Cleanup
    driver.close().expect("driver to close")

  test "pubsub topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin))),

      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin))),

      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin))), # << cursor
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(messages[6][0], messages[6][1])

    ## When
    let res = driver.getMessages(
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=false
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[4..5]

    ## Cleanup
    driver.close().expect("driver to close")


suite "SQLite driver - query by time range":

  test "start time only":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 5
      filteredMessages == messages[2..6]

    ## Cleanup
    driver.close().expect("driver to close")

  test "end time only":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      # end_time
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      endTime=some(ts(45, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 5
      filteredMessages == messages[0..4]

    ## Cleanup
    driver.close().expect("driver to close")

  test "start time and end time":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin))),
      # start_time
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin))),
      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin))),
      # end_time
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin))),
      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      startTime=some(ts(15, timeOrigin)),
      endTime=some(ts(45, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 3
      filteredMessages == expectedMessages[2..4]

    ## Cleanup
    driver.close().expect("driver to close")

  test "invalid time range - no results":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      # end_time
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      startTime=some(ts(45, timeOrigin)),
      endTime=some(ts(15, timeOrigin)),
      maxPageSize=2,
      ascendingOrder=true
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 0

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range start and content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 5
      filteredMessages == messages[2..6]

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range start and content topic - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
      fakeWakuMessage(@[byte 7], ts=ts(70, timeOrigin)),
      fakeWakuMessage(@[byte 8], ts=ts(80, timeOrigin)),
      fakeWakuMessage(@[byte 9], ts=ts(90, timeOrigin)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 5
      filteredMessages == messages[2..6]

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range start, single content topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)), # << cursor
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70, timeOrigin)),
      fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin)),
      fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, messages[3])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 6
      filteredMessages == messages[4..9]

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range start, single content topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)), # << cursor
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70, timeOrigin)),
      fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin)),
      fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin)),
    ]

    for msg in messages:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, messages[6])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == messages[3..4]

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range, content topic, pubsub topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      # start_time
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin))), # << cursor
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin))),
      # end_time
      (pubsubTopic,        fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 6], ts=ts(60, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 7], ts=ts(70, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, messages[1][1])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(0, timeOrigin)),
      endTime=some(ts(45, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[3..4]

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range, content topic, pubsub topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin))),
      # start_time
      (pubsubTopic,        fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 6], ts=ts(60, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 7], ts=ts(70, timeOrigin))),  # << cursor
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin))),
      # end_time
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(messages[7][0], messages[7][1])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(35, timeOrigin)),
      endTime=some(ts(85, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false
    )

    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[4..5]

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range, content topic, pubsub topic and cursor - cursor timestamp out of time range":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin))), # << cursor
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin))),
      # start_time
      (pubsubTopic,        fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 6], ts=ts(60, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 7], ts=ts(70, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin))),
      # end_time
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(messages[1][0], messages[1][1])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(35, timeOrigin)),
      endTime=some(ts(85, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = messages.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 2
      filteredMessages == expectedMessages[4..5]

    ## Cleanup
    driver.close().expect("driver to close")

  test "time range, content topic, pubsub topic and cursor - cursor timestamp out of time range, descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newTestSqliteDriver()

    let timeOrigin = now()
    let messages = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin))), # << cursor
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin))),
      # start_time
      (pubsubTopic,        fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 6], ts=ts(60, timeOrigin))),
      (pubsubTopic,        fakeWakuMessage(@[byte 7], ts=ts(70, timeOrigin))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 8], contentTopic=contentTopic, ts=ts(80, timeOrigin))),
      # end_time
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 9], contentTopic=contentTopic, ts=ts(90, timeOrigin))),
    ]

    for row in messages:
      let (topic, msg) = row
      require driver.put(topic, msg, computeDigest(msg), msg.timestamp).isOk()

    let cursor = computeTestCursor(messages[1][0], messages[1][1])

    ## When
    let res = driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(35, timeOrigin)),
      endTime=some(ts(85, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false,
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 0

    ## Cleanup
    driver.close().expect("driver to close")
