{.used.}

import
  std/[options, sequtils],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/message_store/queue_store,
  ../../waku/v2/node/message_store/sqlite_store,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_store/client,
  ../../waku/v2/utils/time,
  ./testlib/common,
  ./testlib/switch


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()

proc newTestMessageStore(): MessageStore =
  let database = newTestDatabase()
  SqliteStore.init(database).tryGet()

proc newTestWakuStore(switch: Switch, store=newTestMessageStore()): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuStore.new(peerManager, rng, store)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStore(switch: Switch, handler: HistoryQueryHandler): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuStore.new(peerManager, rng, handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStoreClient(switch: Switch, store: MessageStore = nil): WakuStoreClient =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
  WakuStoreClient.new(peerManager, rng, store)


suite "Waku Store - query handler":

  asyncTest "history query handler should be called":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let msg = fakeWakuMessage(contentTopic=DefaultContentTopic)

    var queryHandlerFut = newFuture[(HistoryQuery)]()
    let queryHandler = proc(req: HistoryQuery): HistoryResult =
          queryHandlerFut.complete(req)
          return ok(HistoryResponse(messages: @[msg]))

    let
      server = await newTestWakuStore(serverSwitch, handler=queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let req = HistoryQuery(contentTopics: @[DefaultContentTopic], ascending: true)

    ## When
    let queryRes = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isOk()

    let request = queryHandlerFut.read()
    check:
      request == req

    let response = queryRes.tryGet()
    check:
      response.messages.len == 1
      response.messages == @[msg]

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "history query handler should be called and return an error":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    var queryHandlerFut = newFuture[(HistoryQuery)]()
    let queryHandler = proc(req: HistoryQuery): HistoryResult =
          queryHandlerFut.complete(req)
          return err(HistoryError(kind: HistoryErrorKind.BAD_REQUEST))

    let
      server = await newTestWakuStore(serverSwitch, handler=queryhandler)
      client = newTestWakuStoreClient(clientSwitch)

    let req = HistoryQuery(contentTopics: @[DefaultContentTopic], ascending: true)

    ## When
    let queryRes = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      not queryHandlerFut.failed()
      queryRes.isErr()

    let request = queryHandlerFut.read()
    check:
      request == req

    let error = queryRes.tryError()
    check:
      error.kind == HistoryErrorKind.BAD_REQUEST

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())


procSuite "Waku Store - history query":
  ## Fixtures
  let storeA = block:
      let store = newTestMessageStore()

      let msgList = @[
        fakeWakuMessage(contentTopic=ContentTopic("2"), ts=Timestamp(0)),
        fakeWakuMessage(contentTopic=ContentTopic("1"), ts=Timestamp(1)),
        fakeWakuMessage(contentTopic=ContentTopic("2"), ts=Timestamp(2)),
        fakeWakuMessage(contentTopic=ContentTopic("1"), ts=Timestamp(3)),
        fakeWakuMessage(contentTopic=ContentTopic("2"), ts=Timestamp(4)),
        fakeWakuMessage(contentTopic=ContentTopic("1"), ts=Timestamp(5)),
        fakeWakuMessage(contentTopic=ContentTopic("2"), ts=Timestamp(6)),
        fakeWakuMessage(contentTopic=ContentTopic("1"), ts=Timestamp(7)),
        fakeWakuMessage(contentTopic=ContentTopic("2"), ts=Timestamp(8)),
        fakeWakuMessage(contentTopic=ContentTopic("1"), ts=Timestamp(9))
      ]

      for msg in msgList:
        require store.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

      store

  asyncTest "handle query":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let topic = ContentTopic("1")
    let
      msg1 = fakeWakuMessage(contentTopic=topic)
      msg2 = fakeWakuMessage()

    server.handleMessage("foo", msg1)
    server.handleMessage("foo", msg2)

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let req = HistoryQuery(contentTopics: @[topic])
    let queryRes = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      queryRes.isOk()

    let response = queryRes.tryGet()
    check:
      response.messages.len == 1
      response.messages == @[msg1]

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "handle query with multiple content filters":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let
      topic1 = ContentTopic("1")
      topic2 = ContentTopic("2")
      topic3 = ContentTopic("3")

    let
      msg1 = fakeWakuMessage(contentTopic=topic1)
      msg2 = fakeWakuMessage(contentTopic=topic2)
      msg3 = fakeWakuMessage(contentTopic=topic3)

    server.handleMessage("foo", msg1)
    server.handleMessage("foo", msg2)
    server.handleMessage("foo", msg3)

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let req = HistoryQuery(contentTopics: @[topic1, topic3])
    let queryRes = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      queryRes.isOk()

    let response = queryRes.tryGet()
    check:
      response.messages.len() == 2
      response.messages.anyIt(it == msg1)
      response.messages.anyIt(it == msg3)

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with pubsub topic filter":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
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

    server.handleMessage(pubsubtopic1, msg1)
    server.handleMessage(pubsubtopic2, msg2)
    server.handleMessage(pubsubtopic2, msg3)

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    # this query targets: pubsubtopic1 AND (contentTopic1 OR contentTopic3)
    let req = HistoryQuery(
      pubsubTopic: some(pubsubTopic1),
      contentTopics: @[contentTopic1, contentTopic3]
    )
    let queryRes = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      queryRes.isOk()

    let response = queryRes.tryGet()
    check:
      response.messages.len() == 1
      response.messages.anyIt(it == msg1)

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with pubsub topic filter - no match":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let
      pubsubtopic1 = "queried-topic"
      pubsubtopic2 = "non-queried-topic"

    let
      msg1 = fakeWakuMessage()
      msg2 = fakeWakuMessage()
      msg3 = fakeWakuMessage()

    server.handleMessage(pubsubtopic2, msg1)
    server.handleMessage(pubsubtopic2, msg2)
    server.handleMessage(pubsubtopic2, msg3)

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let req = HistoryQuery(pubsubTopic: some(pubsubTopic1))
    let res = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 0

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with pubsub topic filter - match the entire stored messages":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let pubsubTopic = "queried-topic"

    let
      msg1 = fakeWakuMessage(payload="TEST-1")
      msg2 = fakeWakuMessage(payload="TEST-2")
      msg3 = fakeWakuMessage(payload="TEST-3")

    server.handleMessage(pubsubTopic, msg1)
    server.handleMessage(pubsubTopic, msg2)
    server.handleMessage(pubsubTopic, msg3)

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let req = HistoryQuery(pubsubTopic: some(pubsubTopic))
    let res = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 3
      response.messages.anyIt(it == msg1)
      response.messages.anyIt(it == msg2)
      response.messages.anyIt(it == msg3)

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with forward pagination":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let currentTime = now()
    let msgList = @[
        WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: currentTime - 9),
        WakuMessage(payload: @[byte 1], contentTopic: DefaultContentTopic, timestamp: currentTime - 8),
        WakuMessage(payload: @[byte 2], contentTopic: DefaultContentTopic, timestamp: currentTime - 7),
        WakuMessage(payload: @[byte 3], contentTopic: DefaultContentTopic, timestamp: currentTime - 6),
        WakuMessage(payload: @[byte 4], contentTopic: DefaultContentTopic, timestamp: currentTime - 5),
        WakuMessage(payload: @[byte 5], contentTopic: DefaultContentTopic, timestamp: currentTime - 4),
        WakuMessage(payload: @[byte 6], contentTopic: DefaultContentTopic, timestamp: currentTime - 3),
        WakuMessage(payload: @[byte 7], contentTopic: DefaultContentTopic, timestamp: currentTime - 2),
        WakuMessage(payload: @[byte 8], contentTopic: DefaultContentTopic, timestamp: currentTime - 1),
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic("2"), timestamp: currentTime)
      ]

    for msg in msgList:
      require server.store.put(DefaultPubsubTopic, msg).isOk()

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    var req = HistoryQuery(
      contentTopics: @[DefaultContentTopic],
      pageSize: 2,
      ascending: true
    )
    var res = await client.query(req, peer=serverPeerInfo)
    require res.isOk()

    var
      response = res.tryGet()
      totalMessages = response.messages.len()
      totalQueries = 1

    while response.cursor.isSome():
      require:
        totalQueries <= 4 # Sanity check here and guarantee that the test will not run forever
        response.messages.len() == 2
        response.pageSize == 2
        response.ascending == true

      req.cursor = response.cursor

      # Continue querying
      res = await client.query(req, peer=serverPeerInfo)
      require res.isOk()
      response = res.tryGet()
      totalMessages += response.messages.len()
      totalQueries += 1

    ## Then
    check:
      totalQueries == 4 # 4 queries of pageSize 2
      totalMessages == 8 # 8 messages in total

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with backward pagination":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let currentTime = now()
    let msgList = @[
        WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: currentTime - 9),
        WakuMessage(payload: @[byte 1], contentTopic: DefaultContentTopic, timestamp: currentTime - 8),
        WakuMessage(payload: @[byte 2], contentTopic: DefaultContentTopic, timestamp: currentTime - 7),
        WakuMessage(payload: @[byte 3], contentTopic: DefaultContentTopic, timestamp: currentTime - 6),
        WakuMessage(payload: @[byte 4], contentTopic: DefaultContentTopic, timestamp: currentTime - 5),
        WakuMessage(payload: @[byte 5], contentTopic: DefaultContentTopic, timestamp: currentTime - 4),
        WakuMessage(payload: @[byte 6], contentTopic: DefaultContentTopic, timestamp: currentTime - 3),
        WakuMessage(payload: @[byte 7], contentTopic: DefaultContentTopic, timestamp: currentTime - 2),
        WakuMessage(payload: @[byte 8], contentTopic: DefaultContentTopic, timestamp: currentTime - 1),
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic("2"), timestamp: currentTime)
      ]

    for msg in msgList:
      require server.store.put(DefaultPubsubTopic, msg).isOk()

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    var req = HistoryQuery(
      contentTopics: @[DefaultContentTopic],
      pageSize: 2,
      ascending: false
    )
    var res = await client.query(req, peer=serverPeerInfo)
    require res.isOk()

    var
      response = res.tryGet()
      totalMessages = response.messages.len()
      totalQueries = 1

    while response.cursor.isSome():
      require:
        totalQueries <= 4 # Sanity check here and guarantee that the test will not run forever
        response.messages.len() == 2
        response.pageSize == 2
        response.ascending == false

      req.cursor = response.cursor

      # Continue querying
      res = await client.query(req, peer=serverPeerInfo)
      require res.isOk()
      response = res.tryGet()
      totalMessages += response.messages.len()
      totalQueries += 1

    ## Then
    check:
      totalQueries == 4 # 4 queries of pageSize 2
      totalMessages == 8 # 8 messages in total

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with no paging info - auto-pagination":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let msgList = @[
        WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2")),
        WakuMessage(payload: @[byte 1], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 2], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 3], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 4], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 5], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 6], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 7], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 8], contentTopic: DefaultContentTopic),
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic("2"))
      ]

    for msg in msgList:
      require server.store.put(DefaultPubsubTopic, msg).isOk()

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let req = HistoryQuery(contentTopics: @[DefaultContentTopic])
    let res = await client.query(req, peer=serverPeerInfo)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      ## No pagination specified. Response will be auto-paginated with
      ## up to MaxPageSize messages per page.
      response.messages.len() == 8
      response.cursor.isNone()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle temporal history query with a valid time window":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = newTestWakuStore(serverSwitch, store=storeA)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let req = HistoryQuery(
      contentTopics: @[ContentTopic("1")],
      startTime: some(Timestamp(2)),
      endTime: some(Timestamp(5))
    )

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let res = await client.query(req, peer=serverPeerInfo)

    ## Then
    check res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 2
      response.messages.anyIt(it.timestamp == Timestamp(3))
      response.messages.anyIt(it.timestamp == Timestamp(5))

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle temporal history query with a zero-size time window":
    # a zero-size window results in an empty list of history messages
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch, store=storeA)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let req = HistoryQuery(
      contentTopics: @[ContentTopic("1")],
      startTime: some(Timestamp(2)),
      endTime: some(Timestamp(2))
    )

    let serverPeerInfo =serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let res = await client.query(req, peer=serverPeerInfo)

    ## Then
    check res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len == 0

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle temporal history query with an invalid time window":
    # A history query with an invalid time range results in an empty list of history messages
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let
      server = await newTestWakuStore(serverSwitch, store=storeA)
      client = newTestWakuStoreClient(clientSwitch)

    ## Given
    let req = HistoryQuery(
      contentTopics: @[ContentTopic("1")],
      startTime: some(Timestamp(5)),
      endTime: some(Timestamp(2))
    )

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    ## When
    let res = await client.query(req, peer=serverPeerInfo)

    ## Then
    check res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len == 0

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())


suite "Message Store - message handling":

  asyncTest "it should store a valid and non-ephemeral message":
    ## Setup
    let store = StoreQueueRef.new(5)
    let switch = newTestSwitch()
    let proto = await newTestWakuStore(switch, store)

    ## Given
    let validSenderTime = now()
    let message = fakeWakuMessage(ephemeral=false, ts=validSenderTime)

    ## When
    proto.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      store.getMessagesCount().tryGet() == 1

    ## Cleanup
    await switch.stop()

  asyncTest "it should not store an ephemeral message":
    ## Setup
    let store = StoreQueueRef.new(10)
    let switch = newTestSwitch()
    let proto = await newTestWakuStore(switch, store)

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
      proto.handleMessage(DefaultPubsubTopic, msg)

    ## Then
    check:
      store.len == 2

    ## Cleanup
    await switch.stop()

  asyncTest "it should store a message with no sender timestamp":
    ## Setup
    let store = StoreQueueRef.new(5)
    let switch = newTestSwitch()
    let proto = await newTestWakuStore(switch, store)

    ## Given
    let invalidSenderTime = 0
    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    proto.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      store.getMessagesCount().tryGet() == 1

    ## Cleanup
    await switch.stop()

  asyncTest "it should not store a message with a sender time variance greater than max time variance (future)":
    ## Setup
    let store = StoreQueueRef.new(5)
    let switch = newTestSwitch()
    let proto = await newTestWakuStore(switch, store)

    ## Given
    let
      now = now()
      invalidSenderTime = now + MaxMessageTimestampVariance + 1

    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    proto.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      store.getMessagesCount().tryGet() == 0

    ## Cleanup
    await switch.stop()

  asyncTest "it should not store a message with a sender time variance greater than max time variance (past)":
    ## Setup
    let store = StoreQueueRef.new(5)
    let switch = newTestSwitch()
    let proto = await newTestWakuStore(switch, store)

    ## Given
    let
      now = now()
      invalidSenderTime = now - MaxMessageTimestampVariance - 1

    let message = fakeWakuMessage(ts=invalidSenderTime)

    ## When
    proto.handleMessage(DefaultPubSubTopic, message)

    ## Then
    check:
      store.getMessagesCount().tryGet() == 0

    ## Cleanup
    await switch.stop()
