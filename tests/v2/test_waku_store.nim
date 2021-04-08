{.used.}

import
  std/[options, tables, sets],
  testutils/unittests, chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/rpc/message,
  ../../waku/v2/protocol/[waku_message, message_notifier],
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/node/storage/message/waku_message_store,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../test_helpers, ./utils

procSuite "Waku Store":
  const defaultContentTopic = ContentTopic("1")
  
  asyncTest "handle query":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      topic = defaultContentTopic
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic("2"))

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      subscription = proto.subscription()
      rpc = HistoryQuery(topics: @[topic])

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    await subscriptions.notify("foo", msg)
    await subscriptions.notify("foo", msg2)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 1
        response.messages[0] == msg
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  asyncTest "handle query with store and restarts":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      topic = defaultContentTopic
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic("2"))

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      subscription = proto.subscription()
      rpc = HistoryQuery(topics: @[topic])

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    await subscriptions.notify("foo", msg)
    await subscriptions.notify("foo", msg2)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 1
        response.messages[0] == msg
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    let 
      proto2 = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      key2 = PrivateKey.random(ECDSA, rng[]).get()

    var listenSwitch2 = newStandardSwitch(some(key2))
    discard await listenSwitch2.start()

    proto2.setPeer(listenSwitch2.peerInfo)

    listenSwitch2.mount(proto2)

    var completionFut2 = newFuture[bool]()
    proc handler2(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 1
        response.messages[0] == msg
      completionFut2.complete(true)

    await proto2.query(rpc, handler2)

    check:
      (await completionFut2.withTimeout(5.seconds)) == true

  asyncTest "handle query with forward pagination":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2")),
        WakuMessage(payload: @[byte 1],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 2],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 3],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 4],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 5],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 6],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 7],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 8],contentTopic: defaultContentTopic), 
        WakuMessage(payload: @[byte 9],contentTopic: ContentTopic("2"))]

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      subscription = proto.subscription()
      rpc = HistoryQuery(topics: @[defaultContentTopic], pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD) )
      
    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      await subscriptions.notify("foo", wakuMsg)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 2
        response.pagingInfo.pageSize == 2 
        response.pagingInfo.direction == PagingDirection.FORWARD
        response.pagingInfo.cursor != Index()
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  asyncTest "handle query with backward pagination":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2")),
        WakuMessage(payload: @[byte 1],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 2],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 3],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 4],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 5],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 6],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 7],contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 8],contentTopic: defaultContentTopic), 
        WakuMessage(payload: @[byte 9],contentTopic: ContentTopic("2"))]
            
    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      subscription = proto.subscription()
    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      await subscriptions.notify("foo", wakuMsg)
    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 2
        response.pagingInfo.pageSize == 2 
        response.pagingInfo.direction == PagingDirection.BACKWARD
        response.pagingInfo.cursor != Index()
      completionFut.complete(true)

    let rpc = HistoryQuery(topics: @[defaultContentTopic], pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD) )
    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  asyncTest "handle queries with no pagination":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2")),
        WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 2], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 3], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 4], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 5], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 6], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 7], contentTopic: defaultContentTopic),
        WakuMessage(payload: @[byte 8], contentTopic: defaultContentTopic), 
        WakuMessage(payload: @[byte 9], contentTopic: ContentTopic("2"))]

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      subscription = proto.subscription()
    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      await subscriptions.notify("foo", wakuMsg)
    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 8
        response.pagingInfo == PagingInfo()
      completionFut.complete(true)

    let rpc = HistoryQuery(topics: @[defaultContentTopic] )

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  test "Index Protobuf encoder/decoder test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic))
      pb = index.encode()
      decodedIndex = Index.init(pb.buffer)

    check:
      # the fields of decodedIndex must be the same as the original index
      decodedIndex.isErr == false
      decodedIndex.value == index

    let
      emptyIndex = Index()
      epb = emptyIndex.encode()
      decodedEmptyIndex = Index.init(epb.buffer)

    check:
      # check the correctness of init and encode for an empty Index
      decodedEmptyIndex.isErr == false
      decodedEmptyIndex.value == emptyIndex


  test "PagingDirection Protobuf encod/init test":
    let
      pagingDirection = PagingDirection.BACKWARD
      pb = pagingDirection.encode()
      decodedPagingDirection = PagingDirection.init(pb.buffer)

    check:
      # the decodedPagingDirection must be the same as the original pagingDirection
      decodedPagingDirection.isErr == false
      decodedPagingDirection.value == pagingDirection

  test "PagingInfo Protobuf encod/init test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic))
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.BACKWARD)
      pb = pagingInfo.encode()
      decodedPagingInfo = PagingInfo.init(pb.buffer)

    check:
      # the fields of decodedPagingInfo must be the same as the original pagingInfo
      decodedPagingInfo.isErr == false
      decodedPagingInfo.value == pagingInfo
    
    let
      emptyPagingInfo = PagingInfo()
      epb = emptyPagingInfo.encode()
      decodedEmptyPagingInfo = PagingInfo.init(epb.buffer)

    check:
      # check the correctness of init and encode for an empty PagingInfo
      decodedEmptyPagingInfo.isErr == false
      decodedEmptyPagingInfo.value == emptyPagingInfo
  
  test "HistoryQuery Protobuf encode/init test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic))
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.BACKWARD)
      query=HistoryQuery(topics: @[defaultContentTopic], pagingInfo: pagingInfo, startTime: float64(10), endTime: float64(11))
      pb = query.encode()
      decodedQuery = HistoryQuery.init(pb.buffer)

    check:
      # the fields of decoded query decodedQuery must be the same as the original query query
      decodedQuery.isErr == false
      decodedQuery.value == query
    
    let 
      emptyQuery=HistoryQuery()
      epb = emptyQuery.encode()
      decodedEmptyQuery = HistoryQuery.init(epb.buffer)

    check:
      # check the correctness of init and encode for an empty HistoryQuery
      decodedEmptyQuery.isErr == false
      decodedEmptyQuery.value == emptyQuery
  
  test "HistoryResponse Protobuf encod/init test":
    let
      wm = WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic)
      index = computeIndex(wm)
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.BACKWARD)
      res = HistoryResponse(messages: @[wm], pagingInfo:pagingInfo)
      pb = res.encode()
      decodedRes = HistoryResponse.init(pb.buffer)

    check:
      # the fields of decoded response decodedRes must be the same as the original response res
      decodedRes.isErr == false
      decodedRes.value == res
    
    let 
      emptyRes=HistoryResponse()
      epb = emptyRes.encode()
      decodedEmptyRes = HistoryResponse.init(epb.buffer)

    check:
      # check the correctness of init and encode for an empty HistoryResponse
      decodedEmptyRes.isErr == false
      decodedEmptyRes.value == emptyRes
    
