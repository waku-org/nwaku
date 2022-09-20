{.used.}

import
  std/[options, tables, sets, sequtils, times],
  stew/byteutils,
  testutils/unittests, 
  chronos, 
  chronicles,
  libp2p/switch,
  libp2p/crypto/crypto
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/node/storage/message/message_store,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/pagination,
  ../../waku/v2/utils/time,
  ../test_helpers 


const 
  DefaultPubsubTopic = "/waku/2/default-waku/proto"
  DefaultContentTopic = ContentTopic("/waku/2/default-content/proto")


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.init("", inMemory = true).tryGet()

proc fakeWakuMessage(
  payload = "TEST-PAYLOAD",
  contentTopic = DefaultContentTopic, 
  ts = getNanosecondTime(epochTime()),
  ephemeral = false,
): WakuMessage = 
  WakuMessage(
    payload: toBytes(payload),
    contentTopic: contentTopic,
    version: 1,
    timestamp: ts,
    ephemeral: ephemeral,
  )

proc newTestSwitch(key=none(PrivateKey), address=none(MultiAddress)): Switch =
  let peerKey = key.get(PrivateKey.random(ECDSA, rng[]).get())
  let peerAddr = address.get(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get()) 
  return newStandardSwitch(some(peerKey), addrs=peerAddr)


proc newTestWakuStore(switch: Switch): WakuStore =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    database = newTestDatabase()
    store = SqliteStore.init(database).tryGet()
    proto = WakuStore.init(peerManager, rng, store)

  waitFor proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStore(switch: Switch, store: MessageStore): WakuStore =
  let
    peerManager = PeerManager.new(switch)
    rng = crypto.newRng()
    proto = WakuStore.init(peerManager, rng, store)

  waitFor proto.start()
  switch.mount(proto)

  return proto


suite "Waku Store":
  
  asyncTest "handle query":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let 
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())


    ## Given
    let topic = ContentTopic("1")
    let
      msg1 = fakeWakuMessage(contentTopic=topic)
      msg2 = fakeWakuMessage()

    await serverProto.handleMessage("foo", msg1)
    await serverProto.handleMessage("foo", msg2)

    ## When
    let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: topic)])
    let resQuery = await clientProto.query(rpc)

    ## Then
    check:
      resQuery.isOk()

    let response = resQuery.tryGet() 
    check:
      response.messages.len == 1
      response.messages[0] == msg1

    ## Cleanup
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "handle query with multiple content filters":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let 
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## Given
    let
      topic1 = ContentTopic("1")
      topic2 = ContentTopic("2")
      topic3 = ContentTopic("3")

    let
      msg1 = fakeWakuMessage(contentTopic=topic1)
      msg2 = fakeWakuMessage(contentTopic=topic2)
      msg3 = fakeWakuMessage(contentTopic=topic3)

    await serverProto.handleMessage("foo", msg1)
    await serverProto.handleMessage("foo", msg2)
    await serverProto.handleMessage("foo", msg3)
    
    ## When
    let rpc = HistoryQuery(contentFilters: @[
      HistoryContentFilter(contentTopic: topic1), 
      HistoryContentFilter(contentTopic: topic3)
    ])
    let resQuery = await clientProto.query(rpc)

    ## Then
    check:
      resQuery.isOk()

    let response = resQuery.tryGet() 
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
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

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

    await serverProto.handleMessage(pubsubtopic1, msg1)
    await serverProto.handleMessage(pubsubtopic2, msg2)
    await serverProto.handleMessage(pubsubtopic2, msg3)
    
    ## When
    # this query targets: pubsubtopic1 AND (contentTopic1 OR contentTopic3)    
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: contentTopic1), 
                        HistoryContentFilter(contentTopic: contentTopic3)], 
      pubsubTopic: pubsubTopic1
    )
    let resQuery = await clientProto.query(rpc)

    ## Then
    check:
      resQuery.isOk()

    let response = resQuery.tryGet() 
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
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## Given
    let
      pubsubtopic1 = "queried-topic"
      pubsubtopic2 = "non-queried-topic"

    let
      msg1 = fakeWakuMessage()
      msg2 = fakeWakuMessage()
      msg3 = fakeWakuMessage()

    await serverProto.handleMessage(pubsubtopic2, msg1)
    await serverProto.handleMessage(pubsubtopic2, msg2)
    await serverProto.handleMessage(pubsubtopic2, msg3)

    ## When
    let rpc = HistoryQuery(pubsubTopic: pubsubTopic1)
    let res = await clientProto.query(rpc)

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
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

    ## Given
    let pubsubTopic = "queried-topic"
    
    let
      msg1 = fakeWakuMessage(payload="TEST-1")
      msg2 = fakeWakuMessage(payload="TEST-2")
      msg3 = fakeWakuMessage(payload="TEST-3")

    await serverProto.handleMessage(pubsubTopic, msg1)
    await serverProto.handleMessage(pubsubTopic, msg2)
    await serverProto.handleMessage(pubsubTopic, msg3)
    
    ## When
    let rpc = HistoryQuery(pubsubTopic: pubsubTopic)
    let res = await clientProto.query(rpc)

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
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

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
      await serverProto.handleMessage("foo", msg)

    ## When
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)],
      pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD) 
    )
    let res = await clientProto.query(rpc)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 2
      response.pagingInfo.pageSize == 2 
      response.pagingInfo.direction == PagingDirection.FORWARD
      response.pagingInfo.cursor != Index()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with backward pagination":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let 
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

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
      await serverProto.handleMessage("foo", msg)

    ## When
    let rpc = HistoryQuery(
      contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)],
      pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD) 
    )
    let res = await clientProto.query(rpc)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      response.messages.len() == 2
      response.pagingInfo.pageSize == 2 
      response.pagingInfo.direction == PagingDirection.BACKWARD
      response.pagingInfo.cursor != Index()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle query with no paging info - auto-pagination":
    ## Setup
    let 
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()
    
    await allFutures(serverSwitch.start(), clientSwitch.start())
      
    let 
      serverProto = newTestWakuStore(serverSwitch)
      clientProto = newTestWakuStore(clientSwitch)

    clientProto.setPeer(serverSwitch.peerInfo.toRemotePeerInfo())

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
      await serverProto.handleMessage("foo", msg)

    ## When
    let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: DefaultContentTopic)])
    let res = await clientProto.query(rpc)

    ## Then
    check:
      res.isOk()

    let response = res.tryGet()
    check:
      ## No pagination specified. Response will be auto-paginated with
      ## up to MaxPageSize messages per page.
      response.messages.len() == 8
      response.pagingInfo.pageSize == 8
      response.pagingInfo.direction == PagingDirection.BACKWARD
      response.pagingInfo.cursor != Index()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "handle ephemeral messages":
    ## Setup
    let store = StoreQueueRef.new(10)
    let switch = newTestSwitch()
    let proto = newTestWakuStore(switch, store)
    let msgList = @[ 
      fakeWakuMessage(ephemeral = false, payload = "1"),
      fakeWakuMessage(ephemeral = true, payload = "2"),
      fakeWakuMessage(ephemeral = true, payload = "3"),
      fakeWakuMessage(ephemeral = true, payload = "4"),
      fakeWakuMessage(ephemeral = false, payload = "5"),
    ]

    for msg in msgList:
      await proto.handleMessage(DefaultPubsubTopic, msg)

    check: 
      store.len == 2

    ## Cleanup
    await switch.stop()


# TODO: Review this test suite test cases
procSuite "Waku Store - fault tolerant store":

  proc newTestWakuStore(peer=none(RemotePeerInfo)): Future[(Switch, Switch, WakuStore)] {.async.} =
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let dialSwitch = newStandardSwitch()
    await dialSwitch.start()
    
    let
      peerManager = PeerManager.new(dialsWitch)
      rng = crypto.newRng()
      database = newTestDatabase()
      store = SqliteStore.init(database).tryGet()
      proto = WakuStore.init(peerManager, rng, store)

    let storePeer = peer.get(listenSwitch.peerInfo.toRemotePeerInfo())
    proto.setPeer(storePeer)

    await proto.start()
    listenSwitch.mount(proto)

    return (listenSwitch, dialSwitch, proto)


  asyncTest "temporal history queries":
    ## Setup
    let (listenSwitch, dialSwitch, proto) = await newTestWakuStore()
    let msgList = @[
      WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: Timestamp(0)),
      WakuMessage(payload: @[byte 1], contentTopic: ContentTopic("1"), timestamp: Timestamp(1)),
      WakuMessage(payload: @[byte 2], contentTopic: ContentTopic("2"), timestamp: Timestamp(2)),
      WakuMessage(payload: @[byte 3], contentTopic: ContentTopic("1"), timestamp: Timestamp(3)),
      WakuMessage(payload: @[byte 4], contentTopic: ContentTopic("2"), timestamp: Timestamp(4)),
      WakuMessage(payload: @[byte 5], contentTopic: ContentTopic("1"), timestamp: Timestamp(5)),
      WakuMessage(payload: @[byte 6], contentTopic: ContentTopic("2"), timestamp: Timestamp(6)),
      WakuMessage(payload: @[byte 7], contentTopic: ContentTopic("1"), timestamp: Timestamp(7)),
      WakuMessage(payload: @[byte 8], contentTopic: ContentTopic("2"), timestamp: Timestamp(8)),
      WakuMessage(payload: @[byte 9], contentTopic: ContentTopic("1"), timestamp: Timestamp(9))
    ]

    for msg in msgList:
      await proto.handleMessage(DefaultPubsubTopic, msg)

    let (listenSwitch2, dialSwitch2, proto2) = await newTestWakuStore()
    let msgList2 = @[
      WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: Timestamp(0)),
      WakuMessage(payload: @[byte 11], contentTopic: ContentTopic("1"), timestamp: Timestamp(1)),
      WakuMessage(payload: @[byte 12], contentTopic: ContentTopic("2"), timestamp: Timestamp(2)),
      WakuMessage(payload: @[byte 3], contentTopic: ContentTopic("1"), timestamp: Timestamp(3)),
      WakuMessage(payload: @[byte 4], contentTopic: ContentTopic("2"), timestamp: Timestamp(4)),
      WakuMessage(payload: @[byte 5], contentTopic: ContentTopic("1"), timestamp: Timestamp(5)),
      WakuMessage(payload: @[byte 13], contentTopic: ContentTopic("2"), timestamp: Timestamp(6)),
      WakuMessage(payload: @[byte 14], contentTopic: ContentTopic("1"), timestamp: Timestamp(7))
    ]

    for msg in msgList2:
      await proto2.handleMessage(DefaultPubsubTopic, msg)

    
    asyncTest "handle temporal history query with a valid time window":
      ## Given
      let rpc = HistoryQuery(
        contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], 
        startTime: Timestamp(2), 
        endTime: Timestamp(5)
      )
      
      ## When
      let res = await proto.query(rpc)

      ## Then
      check res.isOk()

      let response = res.tryGet()
      check:
        response.messages.len() == 2
        response.messages.anyIt(it.timestamp == Timestamp(3))
        response.messages.anyIt(it.timestamp == Timestamp(5))
      
    asyncTest "handle temporal history query with a zero-size time window":
      # a zero-size window results in an empty list of history messages
      ## Given
      let rpc = HistoryQuery(
        contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], 
        startTime: Timestamp(2), 
        endTime: Timestamp(2)
      )

      ## When
      let res = await proto.query(rpc)

      ## Then
      check res.isOk()

      let response = res.tryGet()
      check:
        response.messages.len == 0

    asyncTest "handle temporal history query with an invalid time window":
      # A history query with an invalid time range results in an empty list of history messages
      ## Given
      let rpc = HistoryQuery(
        contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], 
        startTime: Timestamp(5), 
        endTime: Timestamp(2)
      )

      ## When
      let res = await proto.query(rpc)

      ## Then
      check res.isOk()

      let response = res.tryGet()
      check:
        response.messages.len == 0

    asyncTest "resume message history":
      ## Given
      # Start a new node
      let (listenSwitch3, dialSwitch3, proto3) = await newTestWakuStore(peer=some(listenSwitch.peerInfo.toRemotePeerInfo()))

      ## When
      let successResult = await proto3.resume()

      ## Then
      check:
        successResult.isOk()
        successResult.value == 10
        proto3.store.getMessagesCount().tryGet() == 10

      ## Cleanup 
      await allFutures(dialSwitch3.stop(), listenSwitch3.stop())

    asyncTest "queryFromWithPaging - no pagingInfo":
      ## Given
      let rpc = HistoryQuery(startTime: Timestamp(2), endTime: Timestamp(5))

      ## When
      let res = await proto.queryFromWithPaging(rpc, listenSwitch.peerInfo.toRemotePeerInfo())

      ## Then
      check res.isOk()
      
      let response = res.tryGet()
      check:
        response.len == 4

    asyncTest "queryFromWithPaging - with pagination":
      var pinfo = PagingInfo(direction:PagingDirection.FORWARD, pageSize: 1)
      let rpc = HistoryQuery(startTime: Timestamp(2), endTime: Timestamp(5), pagingInfo: pinfo)

      let messagesResult = await proto.queryFromWithPaging(rpc, listenSwitch.peerInfo.toRemotePeerInfo())

      check:
        messagesResult.isOk
        messagesResult.value.len == 4

    asyncTest "resume history from a list of offline peers":
      var offListenSwitch = newStandardSwitch(some(PrivateKey.random(ECDSA, rng[]).get()))
      var dialSwitch3 = newStandardSwitch()
      await dialSwitch3.start()
      let proto3 = WakuStore.init(PeerManager.new(dialSwitch3), crypto.newRng())
      let successResult = await proto3.resume(some(@[offListenSwitch.peerInfo.toRemotePeerInfo()]))
      check:
        successResult.isErr

      #free resources
      await allFutures(dialSwitch3.stop(),
        offListenSwitch.stop())

    asyncTest "resume history from a list of candidate peers":

      let offListenSwitch = newStandardSwitch(some(PrivateKey.random(ECDSA, rng[]).get()))
      let (listenSwitch3, dialSwitch3, proto3) = await newTestWakuStore()

      ## When
      let res = await proto3.resume(some(@[
        offListenSwitch.peerInfo.toRemotePeerInfo(),
        listenSwitch.peerInfo.toRemotePeerInfo(),
        listenSwitch2.peerInfo.toRemotePeerInfo()
      ]))

      ## Then
      # `proto3` is expected to retrieve 14 messages because:
      # - the store mounted on `listenSwitch` holds 10 messages (`msgList`)
      # - the store mounted on `listenSwitch2` holds 7 messages (see `msgList2`)
      # - both stores share 3 messages, resulting in 14 unique messages in total
      check res.isOk()

      let response = res.tryGet()
      check:
        response == 14
        proto3.store.getMessagesCount().tryGet() == 14

      ## Cleanup
      await allFutures(listenSwitch3.stop(), dialSwitch3.stop(), offListenSwitch.stop())

    ## Cleanup
    await allFutures(dialSwitch.stop(), dialSwitch2.stop(), listenSwitch.stop(), listenSwitch2.stop())
