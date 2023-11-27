{.used.}

import
  std/[options, sequtils],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto
import
  ../../../waku/common/databases/db_sqlite,
  ../../../waku/waku_core,
  ../../../waku/waku_core/message/digest,
  ../../../waku/waku_archive/driver/sqlite_driver,
  ../../../waku/waku_archive,
  ../testlib/common,
  ../testlib/wakucore


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()

proc newTestArchiveDriver(): ArchiveDriver =
  let db = newTestDatabase()
  SqliteDriver.new(db).tryGet()

proc newTestWakuArchive(driver: ArchiveDriver): WakuArchive =
  WakuArchive.new(driver).get()

proc computeTestCursor(pubsubTopic: PubsubTopic, message: WakuMessage): ArchiveCursor =
  ArchiveCursor(
    pubsubTopic: pubsubTopic,
    senderTime: message.timestamp,
    storeTime: message.timestamp,
    digest: computeDigest(message)
  )



suite "Waku Archive - message handling":

  test "it should driver a valid and non-ephemeral message":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let validSenderTime = now()
    let message = fakeWakuMessage(ephemeral=false, ts=validSenderTime)

    ## When
    waitFor archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      (waitFor driver.getMessagesCount()).tryGet() == 1

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
      waitFor archive.handleMessage(DefaultPubsubTopic, msg)

    ## Then
    check:
      (waitFor driver.getMessagesCount()).tryGet() == 2

  test "it should driver a message with no sender timestamp":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let invalidSenderTime = 0
    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    waitFor archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      (waitFor driver.getMessagesCount()).tryGet() == 1

  test "it should not driver a message with a sender time variance greater than max time variance (future)":
    ## Setup
    let driver = newTestArchiveDriver()
    let archive = newTestWakuArchive(driver)

    ## Given
    let
      now = now()
      invalidSenderTime = now + MaxMessageTimestampVariance + 1_000_000_000 # 1 second over the max variance

    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    waitFor archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      (waitFor driver.getMessagesCount()).tryGet() == 0

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
    waitFor archive.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      (waitFor driver.getMessagesCount()).tryGet() == 0


procSuite "Waku Archive - find messages":
  ## Fixtures
  let timeOrigin = now()
  let msgListA = @[
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

  let archiveA = block:
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    for msg in msgListA:
      require (waitFor driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

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

    waitFor archive.handleMessage("foo", msg1)
    waitFor archive.handleMessage("foo", msg2)

    ## Given
    let req = ArchiveQuery(contentTopics: @[topic])

    ## When
    let queryRes = waitFor archive.findMessages(req)

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

    waitFor archive.handleMessage("foo", msg1)
    waitFor archive.handleMessage("foo", msg2)
    waitFor archive.handleMessage("foo", msg3)

    ## Given
    let req = ArchiveQuery(contentTopics: @[topic1, topic3])

    ## When
    let queryRes = waitFor archive.findMessages(req)

    ## Then
    check:
      queryRes.isOk()

    let response = queryRes.tryGet()
    check:
      response.messages.len() == 2
      response.messages.anyIt(it == msg1)
      response.messages.anyIt(it == msg3)

  test "handle query with more than 10 content filters":
    ## Setup
    let
      driver = newTestArchiveDriver()
      archive = newTestWakuArchive(driver)

    let queryTopics = toSeq(1..15).mapIt(ContentTopic($it))

    ## Given
    let req = ArchiveQuery(contentTopics: queryTopics)

    ## When
    let queryRes = waitFor archive.findMessages(req)

    ## Then
    check:
      queryRes.isErr()

    let error = queryRes.tryError()
    check:
      error.kind == ArchiveErrorKind.INVALID_QUERY
      error.cause == "too many content topics"

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

    waitFor archive.handleMessage(pubsubtopic1, msg1)
    waitFor archive.handleMessage(pubsubtopic2, msg2)
    waitFor archive.handleMessage(pubsubtopic2, msg3)

    ## Given
    # This query targets: pubsubtopic1 AND (contentTopic1 OR contentTopic3)
    let req = ArchiveQuery(
      pubsubTopic: some(pubsubTopic1),
      contentTopics: @[contentTopic1, contentTopic3]
    )

    ## When
    let queryRes = waitFor archive.findMessages(req)

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

    waitFor archive.handleMessage(pubsubtopic2, msg1)
    waitFor archive.handleMessage(pubsubtopic2, msg2)
    waitFor archive.handleMessage(pubsubtopic2, msg3)

    ## Given
    let req = ArchiveQuery(pubsubTopic: some(pubsubTopic1))

    ## When
    let res = waitFor archive.findMessages(req)

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

    waitFor archive.handleMessage(pubsubTopic, msg1)
    waitFor archive.handleMessage(pubsubTopic, msg2)
    waitFor archive.handleMessage(pubsubTopic, msg3)

    ## Given
    let req = ArchiveQuery(pubsubTopic: some(pubsubTopic))

    ## When
    let res = waitFor archive.findMessages(req)

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
    ## Given
    let req = ArchiveQuery(
      pageSize: 4,
      ascending: true
    )

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessage]](3)
    var cursors = newSeq[Option[ArchiveCursor]](3)

    for i in 0..<3:
      let res = waitFor archiveA.findMessages(nextReq)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.cursor

      # Set/update the request cursor
      nextReq.cursor = cursors[i]

    ## Then
    check:
      cursors[0] == some(computeTestCursor(DefaultPubsubTopic, msgListA[3]))
      cursors[1] == some(computeTestCursor(DefaultPubsubTopic, msgListA[7]))
      cursors[2] == none(ArchiveCursor)

    check:
      pages[0] == msgListA[0..3]
      pages[1] == msgListA[4..7]
      pages[2] == msgListA[8..9]

  test "handle query with backward pagination":
    ## Given
    let req = ArchiveQuery(
      pageSize: 4,
      ascending: false  # backward
    )

    ## When
    var nextReq = req # copy

    var pages = newSeq[seq[WakuMessage]](3)
    var cursors = newSeq[Option[ArchiveCursor]](3)

    for i in 0..<3:
      let res = waitFor archiveA.findMessages(nextReq)
      require res.isOk()

      # Keep query response content
      let response = res.get()
      pages[i] = response.messages
      cursors[i] = response.cursor

      # Set/update the request cursor
      nextReq.cursor = cursors[i]

    ## Then
    check:
      cursors[0] == some(computeTestCursor(DefaultPubsubTopic, msgListA[6]))
      cursors[1] == some(computeTestCursor(DefaultPubsubTopic, msgListA[2]))
      cursors[2] == none(ArchiveCursor)

    check:
      pages[0] == msgListA[6..9]
      pages[1] == msgListA[2..5]
      pages[2] == msgListA[0..1]

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
      require (waitFor driver.put(DefaultPubsubTopic, msg, computeDigest(msg), computeMessageHash(DefaultPubsubTopic, msg), msg.timestamp)).isOk()

    ## Given
    let req = ArchiveQuery(contentTopics: @[DefaultContentTopic])

    ## When
    let res = waitFor archive.findMessages(req)

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
    let res = waitFor archiveA.findMessages(req)

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
    let res = waitFor archiveA.findMessages(req)

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
    let res = waitFor archiveA.findMessages(req)

    ## Then
    check res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len == 0
