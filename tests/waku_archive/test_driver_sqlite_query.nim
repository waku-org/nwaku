{.used.}

import
  std/[options, sequtils, random, algorithm], testutils/unittests, chronos, chronicles

import
  waku/[
    common/databases/db_sqlite,
    waku_archive,
    waku_archive/driver/sqlite_driver,
    waku_core,
    waku_core/message/digest,
  ],
  ../testlib/common,
  ../testlib/wakucore,
  ../waku_archive/archive_utils

logScope:
  topics = "test archive _driver"

# Initialize the random number generator
common.randomize()

suite "SQLite driver - query by content topic":
  asyncTest "no content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = DefaultContentTopic, ts = ts(00)),
        fakeWakuMessage(@[byte 1], contentTopic = DefaultContentTopic, ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(maxPageSize = 5, ascendingOrder = true)

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[0 .. 4]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "single content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic], maxPageSize = 2, ascendingOrder = true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 3]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "single content topic with meta field":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00), meta = "meta-0"),
        fakeWakuMessage(@[byte 1], ts = ts(10), meta = "meta-1"),
        fakeWakuMessage(
          @[byte 2], contentTopic = contentTopic, ts = ts(20), meta = "meta-2"
        ),
        fakeWakuMessage(
          @[byte 3], contentTopic = contentTopic, ts = ts(30), meta = "meta-3"
        ),
        fakeWakuMessage(
          @[byte 4], contentTopic = contentTopic, ts = ts(40), meta = "meta-4"
        ),
        fakeWakuMessage(
          @[byte 5], contentTopic = contentTopic, ts = ts(50), meta = "meta-5"
        ),
        fakeWakuMessage(
          @[byte 6], contentTopic = contentTopic, ts = ts(60), meta = "meta-6"
        ),
        fakeWakuMessage(
          @[byte 7], contentTopic = contentTopic, ts = ts(70), meta = "meta-7"
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic], maxPageSize = 2, ascendingOrder = true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 3]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "single content topic - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic], maxPageSize = 2, ascendingOrder = false
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[6 .. 7].reversed()

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "multiple content topic":
    ## Given
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const contentTopic3 = "test-content-topic-3"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic1, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic2, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic3, ts = ts(40)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic1, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic2, ts = ts(60)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic3, ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic1, contentTopic2],
      maxPageSize = 2,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 3]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "single content topic - no results":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = DefaultContentTopic, ts = ts(00)),
        fakeWakuMessage(@[byte 1], contentTopic = DefaultContentTopic, ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = DefaultContentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = DefaultContentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = DefaultContentTopic, ts = ts(40)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic], maxPageSize = 2, ascendingOrder = true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages.len == 0

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "content topic and max page size - not enough messages stored":
    ## Given
    const pageSize: uint = 50

    let driver = newSqliteArchiveDriver()

    for t in 0 ..< 40:
      let msg = fakeWakuMessage(@[byte t], DefaultContentTopic, ts = ts(t))
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[DefaultContentTopic],
      maxPageSize = pageSize,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages.len == 40

    ## Cleanup
    (await driver.close()).expect("driver to close")

suite "SQLite driver - query by pubsub topic":
  asyncTest "pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    ## When
    let res = await driver.getMessages(
      pubsubTopic = some(pubsubTopic), maxPageSize = 2, ascendingOrder = true
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[4 .. 5]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "no pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    ## When
    let res = await driver.getMessages(maxPageSize = 2, ascendingOrder = true)

    ## Then
    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[0 .. 1]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "content topic and pubsub topic":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      pubsubTopic = some(pubsubTopic),
      maxPageSize = 2,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[4 .. 5]

    ## Cleanup
    (await driver.close()).expect("driver to close")

suite "SQLite driver - query by cursor":
  asyncTest "only cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
          # << cursor
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, expected[4])

    ## When
    let res = await driver.getMessages(
      cursor = some(cursor), maxPageSize = 2, ascendingOrder = true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[5 .. 6]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "only cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
          # << cursor
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, expected[4])

    ## When
    let res = await driver.getMessages(
      cursor = some(cursor), maxPageSize = 2, ascendingOrder = false
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 3].reversed()

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "only cursor - invalid":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    var messages =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
      ]

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, fakeWakuMessage())

    ## When
    let res = await driver.getMessages(
      includeData = true,
      contentTopics = @[DefaultContentTopic],
      pubsubTopic = none(PubsubTopic),
      cursor = some(cursor),
      startTime = none(Timestamp),
      endTime = none(Timestamp),
      hashes = @[],
      maxPageSize = 5,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isErr()
      res.error == "cursor not found"

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "content topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
          # << cursor
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
        fakeWakuMessage(@[byte 7], ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, expected[4])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      cursor = some(cursor),
      maxPageSize = 10,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[5 .. 6]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "content topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let expected =
      @[
        fakeWakuMessage(@[byte 0], ts = ts(00)),
        fakeWakuMessage(@[byte 1], ts = ts(10)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60)),
          # << cursor
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, expected[6])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      cursor = some(cursor),
      maxPageSize = 10,
      ascendingOrder = false,
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 5].reversed()

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "pubsub topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00, timeOrigin))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10, timeOrigin))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)
          ),
        ), # << cursor
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 7], contentTopic = contentTopic, ts = ts(70, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)
          ),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    let cursor = computeMessageHash(expected[5][0], expected[5][1])

    ## When
    let res = await driver.getMessages(
      pubsubTopic = some(pubsubTopic),
      cursor = some(cursor),
      maxPageSize = 10,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[6 .. 7]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "pubsub topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00, timeOrigin))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10, timeOrigin))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)
          ),
        ), # << cursor
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 7], contentTopic = contentTopic, ts = ts(70, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)
          ),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    let cursor = computeMessageHash(expected[6][0], expected[6][1])

    ## When
    let res = await driver.getMessages(
      pubsubTopic = some(pubsubTopic),
      cursor = some(cursor),
      maxPageSize = 10,
      ascendingOrder = false,
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[4 .. 5].reversed()

    ## Cleanup
    (await driver.close()).expect("driver to close")

suite "SQLite driver - query by time range":
  asyncTest "start time only":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = contentTopic, ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 1], contentTopic = contentTopic, ts = ts(10, timeOrigin)),
        # start_time
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      startTime = some(ts(15, timeOrigin)), maxPageSize = 10, ascendingOrder = true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 6]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "end time only":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = contentTopic, ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 1], contentTopic = contentTopic, ts = ts(10, timeOrigin)),
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)),
        # end_time
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      endTime = some(ts(45, timeOrigin)), maxPageSize = 10, ascendingOrder = true
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[0 .. 4]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "start time and end time":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00, timeOrigin))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10, timeOrigin))),
        # start_time
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)
          ),
        ),
        # end_time
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 7], contentTopic = contentTopic, ts = ts(70, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)
          ),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    ## When
    let res = await driver.getMessages(
      startTime = some(ts(15, timeOrigin)),
      endTime = some(ts(45, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[2 .. 4]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "invalid time range - no results":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = contentTopic, ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 1], contentTopic = contentTopic, ts = ts(10, timeOrigin)),
        # start_time
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)),
        # end_time
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      startTime = some(ts(45, timeOrigin)),
      endTime = some(ts(15, timeOrigin)),
      maxPageSize = 2,
      ascendingOrder = true,
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages.len == 0

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range start and content topic":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = contentTopic, ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 1], contentTopic = contentTopic, ts = ts(10, timeOrigin)),
        # start_time
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      startTime = some(ts(15, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = true,
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 6]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range start and content topic - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = contentTopic, ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 1], contentTopic = contentTopic, ts = ts(10, timeOrigin)),
        # start_time
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)),
        fakeWakuMessage(@[byte 7], ts = ts(70, timeOrigin)),
        fakeWakuMessage(@[byte 8], ts = ts(80, timeOrigin)),
        fakeWakuMessage(@[byte 9], ts = ts(90, timeOrigin)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      startTime = some(ts(15, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = false,
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[2 .. 6].reversed()

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range start, single content topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = contentTopic, ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 1], contentTopic = contentTopic, ts = ts(10, timeOrigin)),
        # start_time
        fakeWakuMessage(@[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)),
          # << cursor
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)),
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70, timeOrigin)),
        fakeWakuMessage(@[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)),
        fakeWakuMessage(@[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, expected[3])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      cursor = some(cursor),
      startTime = some(ts(15, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = true,
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[4 .. 9]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range start, single content topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        fakeWakuMessage(@[byte 0], contentTopic = contentTopic, ts = ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 1], contentTopic = contentTopic, ts = ts(10, timeOrigin)),
        # start_time
        fakeWakuMessage(@[byte 2], ts = ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 5], ts = ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 6], contentTopic = contentTopic, ts = ts(60, timeOrigin)),
          # << cursor
        fakeWakuMessage(@[byte 7], contentTopic = contentTopic, ts = ts(70, timeOrigin)),
        fakeWakuMessage(@[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)),
        fakeWakuMessage(@[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence", sequence = messages.mapIt(it.payload)

    for msg in messages:
      require (
        await driver.put(
          computeMessageHash(DefaultPubsubTopic, msg), DefaultPubsubTopic, msg
        )
      ).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, expected[6])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      cursor = some(cursor),
      startTime = some(ts(15, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = false,
    )

    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expected[3 .. 4].reversed()

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range, content topic, pubsub topic and cursor":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        # start_time
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00, timeOrigin))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10, timeOrigin))),
          # << cursor
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)
          ),
        ),
        # end_time
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)
          ),
        ),
        (pubsubTopic, fakeWakuMessage(@[byte 6], ts = ts(60, timeOrigin))),
        (pubsubTopic, fakeWakuMessage(@[byte 7], ts = ts(70, timeOrigin))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)
          ),
        ),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)
          ),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    let cursor = computeMessageHash(DefaultPubsubTopic, expected[1][1])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      pubsubTopic = some(pubsubTopic),
      cursor = some(cursor),
      startTime = some(ts(0, timeOrigin)),
      endTime = some(ts(45, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = true,
    )

    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[3 .. 4]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range, content topic, pubsub topic and cursor - descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00, timeOrigin))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10, timeOrigin))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)
          ),
        ),
        # start_time
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)
          ),
        ),
        (pubsubTopic, fakeWakuMessage(@[byte 6], ts = ts(60, timeOrigin))),
        (pubsubTopic, fakeWakuMessage(@[byte 7], ts = ts(70, timeOrigin))), # << cursor
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)
          ),
        ),
        # end_time
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)
          ),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    let cursor = computeMessageHash(expected[7][0], expected[7][1])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      pubsubTopic = some(pubsubTopic),
      cursor = some(cursor),
      startTime = some(ts(35, timeOrigin)),
      endTime = some(ts(85, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = false,
    )

    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[4 .. 5].reversed()

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range, content topic, pubsub topic and cursor - cursor timestamp out of time range":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00, timeOrigin))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10, timeOrigin))),
          # << cursor
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)
          ),
        ),
        # start_time
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)
          ),
        ),
        (pubsubTopic, fakeWakuMessage(@[byte 6], ts = ts(60, timeOrigin))),
        (pubsubTopic, fakeWakuMessage(@[byte 7], ts = ts(70, timeOrigin))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)
          ),
        ),
        # end_time
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)
          ),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    let cursor = computeMessageHash(expected[1][0], expected[1][1])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      pubsubTopic = some(pubsubTopic),
      cursor = some(cursor),
      startTime = some(ts(35, timeOrigin)),
      endTime = some(ts(85, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = true,
    )

    ## Then
    check:
      res.isOk()

    let expectedMessages = expected.mapIt(it[1])
    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages == expectedMessages[4 .. 5]

    ## Cleanup
    (await driver.close()).expect("driver to close")

  asyncTest "time range, content topic, pubsub topic and cursor - cursor timestamp out of time range, descending order":
    ## Given
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let driver = newSqliteArchiveDriver()

    let timeOrigin = now()
    let expected =
      @[
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 0], ts = ts(00, timeOrigin))),
        (DefaultPubsubTopic, fakeWakuMessage(@[byte 1], ts = ts(10, timeOrigin))),
          # << cursor
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 2], contentTopic = contentTopic, ts = ts(20, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 3], contentTopic = contentTopic, ts = ts(30, timeOrigin)
          ),
        ),
        # start_time
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 4], contentTopic = contentTopic, ts = ts(40, timeOrigin)
          ),
        ),
        (
          pubsubTopic,
          fakeWakuMessage(
            @[byte 5], contentTopic = contentTopic, ts = ts(50, timeOrigin)
          ),
        ),
        (pubsubTopic, fakeWakuMessage(@[byte 6], ts = ts(60, timeOrigin))),
        (pubsubTopic, fakeWakuMessage(@[byte 7], ts = ts(70, timeOrigin))),
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 8], contentTopic = contentTopic, ts = ts(80, timeOrigin)
          ),
        ),
        # end_time
        (
          DefaultPubsubTopic,
          fakeWakuMessage(
            @[byte 9], contentTopic = contentTopic, ts = ts(90, timeOrigin)
          ),
        ),
      ]
    var messages = expected

    shuffle(messages)
    debug "randomized message insertion sequence",
      sequence = messages.mapIt(it[1].payload)

    for row in messages:
      let (topic, msg) = row
      require (await driver.put(computeMessageHash(topic, msg), topic, msg)).isOk()

    let cursor = computeMessageHash(expected[1][0], expected[1][1])

    ## When
    let res = await driver.getMessages(
      contentTopics = @[contentTopic],
      pubsubTopic = some(pubsubTopic),
      cursor = some(cursor),
      startTime = some(ts(35, timeOrigin)),
      endTime = some(ts(85, timeOrigin)),
      maxPageSize = 10,
      ascendingOrder = false,
    )

    ## Then
    check:
      res.isOk()

    let filteredMessages = res.tryGet().mapIt(it[2])
    check:
      filteredMessages.len == 0

    ## Cleanup
    (await driver.close()).expect("driver to close")
