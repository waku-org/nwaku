{.used.}

import
  std/[options, sequtils],
  testutils/unittests,
  chronicles,
  libp2p/crypto/crypto
import
  ../../../waku/common/sqlite,
  ../../../waku/v2/node/peer_manager/peer_manager,
  ../../../waku/v2/protocol/waku_message,
  ../../../waku/v2/protocol/waku_archive/driver/sqlite_driver,
  ../../../waku/v2/protocol/waku_archive,
  ../../../waku/v2/utils/time,
  ../testlib/common,
  ../testlib/switch


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()

proc newTestArchiveDriver(): ArchiveDriver =
  let db = newTestDatabase()
  SqliteDriver.new(db).tryGet()

proc newTestWakuArchive(driver: ArchiveDriver): WakuArchive =
  let validator: MessageValidator = DefaultMessageValidator()
  WakuArchive.new(driver, validator=some(validator))


suite "Waku Archive - message handling":

  test "it should driver a valid and non-ephemeral message":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let validSenderTime = now()
    let message = fakeWakuMessage(ephemeral=false, ts=validSenderTime)

    ## When
    archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      driver.getMessagesCount().tryGet() == 1

  test "it should not driver an ephemeral message":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let msgList = @[
      fakeWakuMessage(ephemeral = false, payload = "1"),
      fakeWakuMessage(ephemeral = true, payload = "2"),
      fakeWakuMessage(ephemeral = true, payload = "3"),
      fakeWakuMessage(ephemeral = true, payload = "4"),
      fakeWakuMessage(ephemeral = false, payload = "5"),
    ]

    ## When
    for msg in msgList:
      archive.handleMessage(DefaultPubsubTopic, msg)

    ## Then
    check:
      driver.getMessagesCount().tryGet() == 2

  test "it should driver a message with no sender timestamp":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let invalidSenderTime = 0
    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      driver.getMessagesCount().tryGet() == 1

  test "it should not driver a message with a sender time variance greater than max time variance (future)":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let
      now = now()
      invalidSenderTime = now + MaxMessageTimestampVariance + 1

    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      driver.getMessagesCount().tryGet() == 0

  test "it should not driver a message with a sender time variance greater than max time variance (past)":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let
      now = now()
      invalidSenderTime = now - MaxMessageTimestampVariance - 1

    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      driver.getMessagesCount().tryGet() == 0


procSuite "Waku Archive - find messages":
  ## Fixtures
  let timeOrigin = now()
  let archiveA = block:
      let
        driver = newTestArchiveDriver()
        archive = newTestWakuArchive(driver)

      let msgList = @[
        fakeWakuMessage(@[byte 00], contentTopic=ContentTopic("2"), ts=ts(00, timeOrigin)),
        fakeWakuMessage(@[byte 01], contentTopic=ContentTopic("1"), ts=ts(10, timeOrigin)),
        fakeWakuMessage(@[byte 02], contentTopic=ContentTopic("2"), ts=ts(20, timeOrigin)),
        fakeWakuMessage(@[byte 03], contentTopic=ContentTopic("1"), ts=ts(30, timeOrigin)),
        fakeWakuMessage(@[byte 04], contentTopic=ContentTopic("2"), ts=ts(40, timeOrigin)),
        fakeWakuMessage(@[byte 05], contentTopic=ContentTopic("1"), ts=ts(50, timeOrigin)),
        fakeWakuMessage(@[byte 06], contentTopic=ContentTopic("2"), ts=ts(60, timeOrigin)),
        fakeWakuMessage(@[byte 07], contentTopic=ContentTopic("1"), ts=ts(70, timeOrigin)),
        fakeWakuMessage(@[byte 08], contentTopic=ContentTopic("2"), ts=ts(80, timeOrigin)),
        fakeWakuMessage(@[byte 09], contentTopic=ContentTopic("1"), ts=ts(90, timeOrigin))
      ]

      for msg in msgList:
        require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

      archive

  test "handle query":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let topic = ContentTopic("1")
    let
      msg1 = fakeWakuMessage(contentTopic=topic)
      msg2 = fakeWakuMessage()

    archive.handleMessage("foo", msg1)
    archive.handleMessage("foo", msg2)

    ## Given
    let req = ArchiveQuery(contentTopics: @[topic])

    ## When
    let queryRes = archive.findMessages(req)

    ## Then
    check:
      queryRes.isOk()

    let response = queryRes.tryGet()
    check:
      response.messages.len == 1
      response.messages == @[msg1]

  test "handle query with multiple content filters":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let
      topic1 = ContentTopic("1")
      topic2 = ContentTopic("2")
      topic3 = ContentTopic("3")

    let
      msg1 = fakeWakuMessage(contentTopic=topic1)
      msg2 = fakeWakuMessage(contentTopic=topic2)
      msg3 = fakeWakuMessage(contentTopic=topic3)

    archive.handleMessage("foo", msg1)
    archive.handleMessage("foo", msg2)
    archive.handleMessage("foo", msg3)

    ## Given
    let req = ArchiveQuery(contentTopics: @[topic1, topic3])

    ## When
    let queryRes = archive.findMessages(req)

    ## Then
    check:
      queryRes.isOk()

    let response = queryRes.tryGet()
    check:
      response.messages.len() == 2
      response.messages.anyIt(it == msg1)
      response.messages.anyIt(it == msg3)

  test "handle query with pubsub topic filter":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let
      pubsubTopic1 = "queried-topic"
      pubsubTopic2 = "non-queried-topic"

    let
      contentTopic1 = ContentTopic("1")
      contentTopic2 = ContentTopic("2")
      contentTopic3 = ContentTopic("3")

    let
      msg1 = fakeWakuMessage(contentTopic=contentTopic1)
      msg2 = fakeWakuMessage(contentTopic=contentTopic2)
      msg3 = fakeWakuMessage(contentTopic=contentTopic3)

    archive.handleMessage(pubsubtopic1, msg1)
    archive.handleMessage(pubsubtopic2, msg2)
    archive.handleMessage(pubsubtopic2, msg3)

    ## Given
    # This query targets: pubsubtopic1 AND (contentTopic1 OR contentTopic3)
    let req = ArchiveQuery(
      pubsubTopic: some(pubsubTopic1),
      contentTopics: @[contentTopic1, contentTopic3]
    )

    ## When
    let queryRes = archive.findMessages(req)

    ## Then
    check:
      queryRes.isOk()

    let response = queryRes.tryGet()
    check:
      response.messages.len() == 1
      response.messages.anyIt(it == msg1)

  test "handle query with pubsub topic filter - no match":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let
      pubsubtopic1 = "queried-topic"
      pubsubtopic2 = "non-queried-topic"

    let
      msg1 = fakeWakuMessage()
      msg2 = fakeWakuMessage()
      msg3 = fakeWakuMessage()

    archive.handleMessage(pubsubtopic2, msg1)
    archive.handleMessage(pubsubtopic2, msg2)
    archive.handleMessage(pubsubtopic2, msg3)

    ## Given
    let req = ArchiveQuery(pubsubTopic: some(pubsubTopic1))

    ## When
    let res = archive.findMessages(req)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 0

  test "handle query with pubsub topic filter - match the entire stored messages":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let pubsubTopic = "queried-topic"

    let
      msg1 = fakeWakuMessage(payload="TEST-1")
      msg2 = fakeWakuMessage(payload="TEST-2")
      msg3 = fakeWakuMessage(payload="TEST-3")

    archive.handleMessage(pubsubTopic, msg1)
    archive.handleMessage(pubsubTopic, msg2)
    archive.handleMessage(pubsubTopic, msg3)

    ## Given
    let req = ArchiveQuery(pubsubTopic: some(pubsubTopic))

    ## When
    let res = archive.findMessages(req)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 3
      response.messages.anyIt(it == msg1)
      response.messages.anyIt(it == msg2)
      response.messages.anyIt(it == msg3)

  test "handle query with forward pagination":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let currentTime = now()
    let msgList = @[
        fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("2"), ts=currentTime - 9),
        fakeWakuMessage(@[byte 1], contentTopic=DefaultContentTopic, ts=currentTime - 8),
        fakeWakuMessage(@[byte 2], contentTopic=DefaultContentTopic, ts=currentTime - 7),
        fakeWakuMessage(@[byte 3], contentTopic=DefaultContentTopic, ts=currentTime - 6),
        fakeWakuMessage(@[byte 4], contentTopic=DefaultContentTopic, ts=currentTime - 5),
        fakeWakuMessage(@[byte 5], contentTopic=DefaultContentTopic, ts=currentTime - 4),
        fakeWakuMessage(@[byte 6], contentTopic=DefaultContentTopic, ts=currentTime - 3),
        fakeWakuMessage(@[byte 7], contentTopic=DefaultContentTopic, ts=currentTime - 2),
        fakeWakuMessage(@[byte 8], contentTopic=DefaultContentTopic, ts=currentTime - 1),
        fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("2"), ts=currentTime)
      ]

    for msg in msgList:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## Given
    var req = ArchiveQuery(
      contentTopics: @[DefaultContentTopic],
      pageSize: 2,
      ascending: true
    )

    ## When
    var res = archive.findMessages(req)
    require res.isOk()

    var
      response = res.tryGet()
      totalMessages = response.messages.len()
      totalQueries = 1

    while response.cursor.isSome():
      require:
        totalQueries <= 4 # Sanity check here and guarantee that the test will not run forever
        response.messages.len() == 2

      req.cursor = response.cursor

      # Continue querying
      res = archive.findMessages(req)
      require res.isOk()
      response = res.tryGet()
      totalMessages += response.messages.len()
      totalQueries += 1

    ## Then
    check:
      totalQueries == 4 # 4 queries of pageSize 2
      totalMessages == 8 # 8 messages in total

  test "handle query with backward pagination":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let currentTime = now()
    let msgList = @[
        fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("2"), ts=currentTime - 9),
        fakeWakuMessage(@[byte 1], contentTopic=DefaultContentTopic, ts=currentTime - 8),
        fakeWakuMessage(@[byte 2], contentTopic=DefaultContentTopic, ts=currentTime - 7),
        fakeWakuMessage(@[byte 3], contentTopic=DefaultContentTopic, ts=currentTime - 6),
        fakeWakuMessage(@[byte 4], contentTopic=DefaultContentTopic, ts=currentTime - 5),
        fakeWakuMessage(@[byte 5], contentTopic=DefaultContentTopic, ts=currentTime - 4),
        fakeWakuMessage(@[byte 6], contentTopic=DefaultContentTopic, ts=currentTime - 3),
        fakeWakuMessage(@[byte 7], contentTopic=DefaultContentTopic, ts=currentTime - 2),
        fakeWakuMessage(@[byte 8], contentTopic=DefaultContentTopic, ts=currentTime - 1),
        fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("2"), ts=currentTime)
      ]

    for msg in msgList:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## Given
    var req = ArchiveQuery(
      contentTopics: @[DefaultContentTopic],
      pageSize: 2,
      ascending: false
    )

    ## When
    var res = archive.findMessages(req)
    require res.isOk()

    var
      response = res.tryGet()
      totalMessages = response.messages.len()
      totalQueries = 1

    while response.cursor.isSome():
      require:
        totalQueries <= 4 # Sanity check here and guarantee that the test will not run forever
        response.messages.len() == 2

      req.cursor = response.cursor

      # Continue querying
      res = archive.findMessages(req)
      require res.isOk()
      response = res.tryGet()
      totalMessages += response.messages.len()
      totalQueries += 1

    ## Then
    check:
      totalQueries == 4 # 4 queries of pageSize 2
      totalMessages == 8 # 8 messages in total

  test "handle query with no paging info - auto-pagination":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let msgList = @[
        fakeWakuMessage(@[byte 0], contentTopic=ContentTopic("2")),
        fakeWakuMessage(@[byte 1], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 2], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 3], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 4], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 5], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 6], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 7], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 8], contentTopic=DefaultContentTopic),
        fakeWakuMessage(@[byte 9], contentTopic=ContentTopic("2"))
      ]

    for msg in msgList:
      require driver.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

    ## Given
    let req = ArchiveQuery(contentTopics: @[DefaultContentTopic])

    ## When
    let res = archive.findMessages(req)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      ## No pagination specified. Response will be auto-paginated with
      ## up to MaxPageSize messages per page.
      response.messages.len() == 8
      response.cursor.isNone()

  test "handle temporal history query with a valid time window":
    ## Given
    let req = ArchiveQuery(
      contentTopics: @[ContentTopic("1")],
      startTime: some(ts(15, timeOrigin)),
      endTime: some(ts(55, timeOrigin)),
      ascending: true
    )

    ## When
    let res = archiveA.findMessages(req)

    ## Then
    check res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 2
      response.messages.mapIt(it.timestamp) == @[ts(30, timeOrigin), ts(50, timeOrigin)]

  test "handle temporal history query with a zero-size time window":
    ## A zero-size window results in an empty list of history messages
    ## Given
    let req = ArchiveQuery(
      contentTopics: @[ContentTopic("1")],
      startTime: some(Timestamp(2)),
      endTime: some(Timestamp(2))
    )

    ## When
    let res = archiveA.findMessages(req)

    ## Then
    check res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len == 0

  test "handle temporal history query with an invalid time window":
    ## A history query with an invalid time range results in an empty list of history messages
    ## Given
    let req = ArchiveQuery(
      contentTopics: @[ContentTopic("1")],
      startTime: some(Timestamp(5)),
      endTime: some(Timestamp(2))
    )

    ## When
    let res = archiveA.findMessages(req)

    ## Then
    check res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len == 0
