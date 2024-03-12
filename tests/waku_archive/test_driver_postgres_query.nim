{.used.}

import
  std/[options, sequtils, random, algorithm],
  testutils/unittests,
  chronos,
  chronicles
import
  ../../../waku/waku_archive,
  ../../../waku/waku_archive/driver as driver_module,
  ../../../waku/waku_archive/driver/postgres_driver,
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/testasync,
  ../testlib/postgres


logScope:
  topics = "test archive postgres driver"


## This whole file is copied from the 'test_driver_sqlite_query.nim' file
## and it tests the same use cases but using the postgres driver.

# Initialize the random number generator
common.randomize()

proc computeTestCursor(pubsubTopic: PubsubTopic, message: WakuMessage): ArchiveCursor =
  ArchiveCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: computeDigest(message),
    hash: computeMessageHash(pubsubTopic, message)
  )

suite "Postgres driver - queries":
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

  asyncTest "no content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=DefaultContentTopic, ts=ts(00)),
      fakeWakuMessage(@[byte 1], contentTopic=DefaultContentTopic, ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)),

      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      maxPageSize=5,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[0..4]

  asyncTest "single content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),

      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),

      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[2..3]

  asyncTest "single content topic - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),

      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),

      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      maxPageSize=2,
      ascendingOrder=false
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[6..7].reversed()

  asyncTest "multiple content topic":
    ## Given
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const contentTopic3 = "test-content-topic-3"

    let expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),

      fakeWakuMessage(@[byte 2], contentTopic=contentTopic1, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic2, ts=ts(30)),

      fakeWakuMessage(@[byte 4], contentTopic=contentTopic3, ts=ts(40)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic1, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic2, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic3, ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    var res = await driver.getMessages(
      contentTopic= @[contentTopic1, contentTopic2],
      pubsubTopic=some(DefaultPubsubTopic),
      maxPageSize=2,
      ascendingOrder=true,
      startTime=some(ts(00)),
      endTime=some(ts(40))
    )

    ## Then
    assert res.isOk(), res.error
    var filteredMessages = res.tryGet().mapIt(it[1])
    check filteredMessages == expected[2..3]

    ## When
    ## This is very similar to the previous one but we enforce to use the prepared
    ## statement by querying one single content topic
    res = await driver.getMessages(
      contentTopic= @[contentTopic1],
      pubsubTopic=some(DefaultPubsubTopic),
      maxPageSize=2,
      ascendingOrder=true,
      startTime=some(ts(00)),
      endTime=some(ts(40))
    )

    ## Then
    assert res.isOk(), res.error
    filteredMessages = res.tryGet().mapIt(it[1])
    check filteredMessages == @[expected[2]]

  asyncTest "single content topic - no results":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=DefaultContentTopic, ts=ts(00)),
      fakeWakuMessage(@[byte 1], contentTopic=DefaultContentTopic, ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=DefaultContentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=DefaultContentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=DefaultContentTopic, ts=ts(40)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 0

  asyncTest "content topic and max page size - not enough messages stored":
    ## Given
    const pageSize: uint = 50

    for t in 0..<40:
      let msg = fakeWakuMessage(@[byte t], DefaultContentTopic, ts=ts(t))
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[DefaultContentTopic],
      maxPageSize=pageSize,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 40

  asyncTest "pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let expected = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30))),

      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50))),
      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70))),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      pubsubTopic=some(pubsubTopic),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[4..5]

  asyncTest "no pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let expected = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10))),

      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30))),
      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50))),
      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70))),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[0..1]

  asyncTest "content topic and pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let expected = @[
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts=ts(00))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts=ts(10))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20))),
      (DefaultPubsubTopic, fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30))),

      (pubsubTopic, fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40))),
      (pubsubTopic, fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50))),

      (pubsubTopic, fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60))),
      (pubsubTopic, fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70))),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[4..5]

  asyncTest "only cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)), # << cursor

      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),

      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, expected[4])

    ## When
    let res = await driver.getMessages(
      cursor=some(cursor),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[5..6]

  asyncTest "only cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),

      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),

      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)), # << cursor
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, expected[4])

    ## When
    let res = await driver.getMessages(
      cursor=some(cursor),
      maxPageSize=2,
      ascendingOrder=false
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[2..3].reversed()

  asyncTest "content topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)), # << cursor
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)),
      fakeWakuMessage(@[byte 7], ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, expected[4])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[5..6]

  asyncTest "content topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00)),
      fakeWakuMessage(@[byte 1], ts=ts(10)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60)), # << cursor
      fakeWakuMessage(@[byte 7], contentTopic=contentTopic, ts=ts(70)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, expected[6])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=false
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[2..5].reversed()

  asyncTest "pubsub topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(expected[5][0], expected[5][1])

    ## When
    let res = await driver.getMessages(
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[6..7]

  asyncTest "pubsub topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(expected[6][0], expected[6][1])

    ## When
    let res = await driver.getMessages(
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      maxPageSize=10,
      ascendingOrder=false
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[4..5].reversed()

  asyncTest "only hashes - descending order":
    ## Given
    let timeOrigin = now()
    var expected = @[
      fakeWakuMessage(@[byte 0], ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], ts=ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 2], ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4],  ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5],  ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6],  ts=ts(60, timeOrigin)),
      fakeWakuMessage(@[byte 7],  ts=ts(70, timeOrigin)),
      fakeWakuMessage(@[byte 8],  ts=ts(80, timeOrigin)),
      fakeWakuMessage(@[byte 9],  ts=ts(90, timeOrigin)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    let hashes = messages.mapIt(computeMessageHash(DefaultPubsubTopic, it))

    for (msg, hash) in messages.zip(hashes):
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), hash, msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      hashes=hashes,
      ascendingOrder=false
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.reversed()
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages

  asyncTest "start time only":
    ## Given
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[2..6]

  asyncTest "end time only":
    ## Given
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      # end_time
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      endTime=some(ts(45, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[0..4]

  asyncTest "start time and end time":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      startTime=some(ts(15, timeOrigin)),
      endTime=some(ts(45, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[2..4]

  asyncTest "invalid time range - no results":
    ## Given
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      startTime=some(ts(45, timeOrigin)),
      endTime=some(ts(15, timeOrigin)),
      maxPageSize=2,
      ascendingOrder=true
    )

    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 0

  asyncTest "time range start and content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      # start_time
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[2..6]

  asyncTest "time range start and content topic - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false
    )

    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[2..6].reversed()

  asyncTest "time range start, single content topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, expected[3])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[4..9]

  asyncTest "time range start, single content topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, expected[6])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      cursor=some(cursor),
      startTime=some(ts(15, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false
    )

    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expected[3..4].reversed()

  asyncTest "time range, content topic, pubsub topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(DefaultPubsubTopic, expected[1][1])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(0, timeOrigin)),
      endTime=some(ts(45, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[3..4]

  asyncTest "time range, content topic, pubsub topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(expected[7][0], expected[7][1])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(35, timeOrigin)),
      endTime=some(ts(85, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false
    )

    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[4..5].reversed()

  asyncTest "time range, content topic, pubsub topic and cursor - cursor timestamp out of time range":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(expected[1][0], expected[1][1])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(35, timeOrigin)),
      endTime=some(ts(85, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=true
    )

    ## Then
    assert res.isOk(), res.error

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages == expectedMessages[4..5]

  asyncTest "time range, content topic, pubsub topic and cursor - cursor timestamp out of time range, descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let timeOrigin = now()
    let expected = @[
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
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(topic, msg, computeDigest(msg), computeMessageHash(topic, msg), msg.timestamp)).isOk()

    let cursor = computeTestCursor(expected[1][0], expected[1][1])

    ## When
    let res = await driver.getMessages(
      contentTopic= @[contentTopic],
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      startTime=some(ts(35, timeOrigin)),
      endTime=some(ts(85, timeOrigin)),
      maxPageSize=10,
      ascendingOrder=false,
    )

    ## Then
    assert res.isOk(), res.error

    let filteredMessages = res.tryGet().mapIt(it[1])
    check:
      filteredMessages.len == 0

  asyncTest "Get oldest and newest message timestamp":
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let oldestTime = ts(00, timeOrigin)
    let newestTime = ts(100, timeOrigin)
    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=oldestTime),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=newestTime),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    var res = await driver.getOldestMessageTimestamp()
    assert res.isOk(), res.error
    assert res.get() == oldestTime, "Failed to retrieve the latest timestamp"

    res = await driver.getNewestMessageTimestamp()
    assert res.isOk(), res.error
    assert res.get() == newestTime, "Failed to retrieve the newest timestamp"

  asyncTest "Delete messages older than certain timestamp":
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let targetTime = ts(40, timeOrigin)
    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=targetTime),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    var res = await driver.getMessagesCount()
    assert res.isOk(), res.error
    assert res.get() == 7, "Failed to retrieve the initial number of messages"

    let deleteRes = await driver.deleteMessagesOlderThanTimestamp(targetTime)
    assert deleteRes.isOk(), deleteRes.error

    res = await driver.getMessagesCount()
    assert res.isOk(), res.error
    assert res.get() == 3, "Failed to retrieve the # of messages after deletion"

  asyncTest "Keep last n messages":
    const contentTopic = "test-content-topic"

    let timeOrigin = now()
    let expected = @[
      fakeWakuMessage(@[byte 0], contentTopic=contentTopic, ts=ts(00, timeOrigin)),
      fakeWakuMessage(@[byte 1], contentTopic=contentTopic, ts=ts(10, timeOrigin)),
      fakeWakuMessage(@[byte 2], contentTopic=contentTopic, ts=ts(20, timeOrigin)),
      fakeWakuMessage(@[byte 3], contentTopic=contentTopic, ts=ts(30, timeOrigin)),
      fakeWakuMessage(@[byte 4], contentTopic=contentTopic, ts=ts(40, timeOrigin)),
      fakeWakuMessage(@[byte 5], contentTopic=contentTopic, ts=ts(50, timeOrigin)),
      fakeWakuMessage(@[byte 6], contentTopic=contentTopic, ts=ts(60, timeOrigin)),
    ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence=messages.mapIt(it.payload)

    for msg in messages:
      require (await driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    var res = await driver.getMessagesCount()
    assert res.isOk(), res.error
    assert res.get() == 7, "Failed to retrieve the initial number of messages"

    let deleteRes = await driver.deleteOldestMessagesNotWithinLimit(2)
    assert deleteRes.isOk(), deleteRes.error

    res = await driver.getMessagesCount()
    assert res.isOk(), res.error
    assert res.get() == 2, "Failed to retrieve the # of messages after deletion"

  asyncTest "Exists table":

    var existsRes = await driver.existsTable("version")
    assert existsRes.isOk(), existsRes.error
    check existsRes.get() == true

