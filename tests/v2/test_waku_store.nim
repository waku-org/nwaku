{.used.}

import
  std/[options, tables, sets, sequtils],
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
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: topic)])

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
  asyncTest "handle query with multiple content filters":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      topic1 = defaultContentTopic
      topic2 = ContentTopic("2")
      topic3 = ContentTopic("3")
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic1)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic2)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic3)

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      subscription = proto.subscription()
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: topic1), HistoryContentFilter(contentTopic: topic3)])

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    await subscriptions.notify("foo", msg1)
    await subscriptions.notify("foo", msg2)
    await subscriptions.notify("foo", msg3)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 2
        response.messages.anyIt(it == msg1)
        response.messages.anyIt(it == msg3)
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
  
  asyncTest "handle query with pubsub topic filter":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      contentTopic1 = defaultContentTopic
      contentTopic2 = ContentTopic("2")
      contentTopic3 = ContentTopic("3")
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic1)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic2)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic3)

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      pubsubtopic1 = "queried topic"
      pubsubtopic2 = "non queried topic"
      subscription: MessageNotificationSubscription = proto.subscription() 
      # this query targets: pubsubtopic1 AND (contentTopic1 OR contentTopic3)    
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic1), HistoryContentFilter(contentTopic: contentTopic3)], pubsubTopic: pubsubTopic1)

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    # publish messages
    await subscriptions.notify(pubsubtopic1, msg1)
    await subscriptions.notify(pubsubtopic2, msg2)
    await subscriptions.notify(pubsubtopic2, msg3)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 1
        # msg1 is the only match for the query predicate pubsubtopic1 AND (contentTopic1 OR contentTopic3) 
        response.messages.anyIt(it == msg1)
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

  asyncTest "handle query with pubsub topic filter with no match":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      pubsubtopic1 = "queried topic"
      pubsubtopic2 = "non queried topic"
      subscription: MessageNotificationSubscription = proto.subscription() 
      # this query targets: pubsubtopic1  
      rpc = HistoryQuery(pubsubTopic: pubsubTopic1)

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    # publish messages
    await subscriptions.notify(pubsubtopic2, msg1)
    await subscriptions.notify(pubsubtopic2, msg2)
    await subscriptions.notify(pubsubtopic2, msg3)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 0
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
  asyncTest "handle query with pubsub topic filter matching the entire stored messages":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng())
      pubsubtopic = "queried topic"
      subscription: MessageNotificationSubscription = proto.subscription() 
      # this query targets: pubsubtopic 
      rpc = HistoryQuery(pubsubTopic: pubsubtopic)

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    # publish messages
    await subscriptions.notify(pubsubtopic, msg1)
    await subscriptions.notify(pubsubtopic, msg2)
    await subscriptions.notify(pubsubtopic, msg3)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 3
        response.messages.anyIt(it == msg1)
        response.messages.anyIt(it == msg2)
        response.messages.anyIt(it == msg3)
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
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: topic)])

    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    await subscriptions.notify("foo", msg)
    await sleepAsync(1.millis)  # Sleep a millisecond to ensure messages are stored chronologically
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
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: defaultContentTopic)], pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD) )
      
    proto.setPeer(listenSwitch.peerInfo)

    var subscriptions = newTable[string, MessageNotificationSubscription]()
    subscriptions["test"] = subscription

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      await subscriptions.notify("foo", wakuMsg)
      await sleepAsync(1.millis)  # Sleep a millisecond to ensure messages are stored chronologically

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
      await sleepAsync(1.millis)  # Sleep a millisecond to ensure messages are stored chronologically
    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 2
        response.pagingInfo.pageSize == 2 
        response.pagingInfo.direction == PagingDirection.BACKWARD
        response.pagingInfo.cursor != Index()
      completionFut.complete(true)

    let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: defaultContentTopic)], pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD) )
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
      await sleepAsync(1.millis)  # Sleep a millisecond to ensure messages are stored chronologically
    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 8
        response.pagingInfo == PagingInfo()
      completionFut.complete(true)

    let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: defaultContentTopic)] )

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

  test "PagingInfo Protobuf encod/init test":
    let
      index = computeIndex(WakuMessage(payload: @[byte 1], contentTopic: defaultContentTopic))
      pagingInfo = PagingInfo(pageSize: 1, cursor: index, direction: PagingDirection.FORWARD)
      pb = pagingInfo.encode()
      decodedPagingInfo = PagingInfo.init(pb.buffer)

    check:
      # the fields of decodedPagingInfo must be the same as the original pagingInfo
      decodedPagingInfo.isErr == false
      decodedPagingInfo.value == pagingInfo
      decodedPagingInfo.value.direction == pagingInfo.direction
    
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
      query = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: defaultContentTopic), HistoryContentFilter(contentTopic: defaultContentTopic)], pagingInfo: pagingInfo, startTime: float64(10), endTime: float64(11))
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
  
  test "HistoryResponse Protobuf encode/init test":
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
    
  asyncTest "temporal history queries":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: float(0)),
        WakuMessage(payload: @[byte 1],contentTopic: ContentTopic("1"), timestamp: float(1)),
        WakuMessage(payload: @[byte 2],contentTopic: ContentTopic("2"), timestamp: float(2)),
        WakuMessage(payload: @[byte 3],contentTopic: ContentTopic("1"), timestamp: float(3)),
        WakuMessage(payload: @[byte 4],contentTopic: ContentTopic("2"), timestamp: float(4)),
        WakuMessage(payload: @[byte 5],contentTopic: ContentTopic("1"), timestamp: float(5)),
        WakuMessage(payload: @[byte 6],contentTopic: ContentTopic("2"), timestamp: float(6)),
        WakuMessage(payload: @[byte 7],contentTopic: ContentTopic("1"), timestamp: float(7)),
        WakuMessage(payload: @[byte 8],contentTopic: ContentTopic("2"), timestamp: float(8)),
        WakuMessage(payload: @[byte 9],contentTopic: ContentTopic("1"),timestamp: float(9))]
            
    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    # to be connected to
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
      # the pubsub topic should be DefaultTopic
      await subscriptions.notify(DefaultTopic, wakuMsg)
    
    asyncTest "handle temporal history query with a valid time window":
      var completionFut = newFuture[bool]()

      proc handler(response: HistoryResponse) {.gcsafe, closure.} =
        check:
          response.messages.len() == 2
          response.messages.anyIt(it.timestamp == float(3))
          response.messages.anyIt(it.timestamp == float(5))
        completionFut.complete(true)

      let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], startTime: float(2), endTime: float(5))
      await proto.query(rpc, handler)

      check:
        (await completionFut.withTimeout(5.seconds)) == true

    asyncTest "handle temporal history query with a zero-size time window":
      # a zero-size window results in an empty list of history messages
      var completionFut = newFuture[bool]()

      proc handler(response: HistoryResponse) {.gcsafe, closure.} =
        check:
          # a zero-size window results in an empty list of history messages
          response.messages.len() == 0
        completionFut.complete(true)

      let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], startTime: float(2), endTime: float(2))
      await proto.query(rpc, handler)

      check:
        (await completionFut.withTimeout(5.seconds)) == true

    asyncTest "handle temporal history query with an invalid time window":
      # a history query with an invalid time range results in an empty list of history messages
      var completionFut = newFuture[bool]()

      proc handler(response: HistoryResponse) {.gcsafe, closure.} =
        check:
          # a history query with an invalid time range results in an empty list of history messages
          response.messages.len() == 0
        completionFut.complete(true)

      # time window is invalid since start time > end time
      let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], startTime: float(5), endTime: float(2))
      await proto.query(rpc, handler)

      check:
        (await completionFut.withTimeout(5.seconds)) == true

    test "find last seen message":
      var
        msgList = @[IndexedWakuMessage(msg: WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 1],contentTopic: ContentTopic("1"), timestamp: float(1))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 2],contentTopic: ContentTopic("2"), timestamp: float(2))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 3],contentTopic: ContentTopic("1"), timestamp: float(3))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 4],contentTopic: ContentTopic("2"), timestamp: float(4))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 5],contentTopic: ContentTopic("1"), timestamp: float(9))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 6],contentTopic: ContentTopic("2"), timestamp: float(6))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 7],contentTopic: ContentTopic("1"), timestamp: float(7))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 8],contentTopic: ContentTopic("2"), timestamp: float(8))),
          IndexedWakuMessage(msg: WakuMessage(payload: @[byte 9],contentTopic: ContentTopic("1"),timestamp: float(5)))]     

      check:
        findLastSeen(msgList) == float(9)

    asyncTest "resume message history":
      # starts a new node
      var dialSwitch2 = newStandardSwitch()
      discard await dialSwitch2.start()
    
      let proto2 = WakuStore.init(PeerManager.new(dialSwitch2), crypto.newRng())
      proto2.setPeer(listenSwitch.peerInfo)

      let successResult = await proto2.resume()
      check:
        successResult.isOk 
        successResult.value == 10
        proto2.messages.len == 10

    asyncTest "queryFrom":

      var completionFut = newFuture[bool]()

      proc handler(response: HistoryResponse) {.gcsafe, closure.} =
        check:
          response.messages.len() == 4
        completionFut.complete(true)

      let rpc = HistoryQuery(startTime: float(2), endTime: float(5))
      let successResult = await proto.queryFrom(rpc, handler, listenSwitch.peerInfo)

      check:
        (await completionFut.withTimeout(5.seconds)) == true
        successResult.isOk
        successResult.value == 4


    asyncTest "resume history from a list of candidate peers":

      var offListenSwitch = newStandardSwitch(some(PrivateKey.random(ECDSA, rng[]).get()))

      # starts a new node
      var dialSwitch3 = newStandardSwitch()
      discard await dialSwitch3.start()
      let proto3 = WakuStore.init(PeerManager.new(dialSwitch3), crypto.newRng())

      let successResult = await proto3.resume(some(@[offListenSwitch.peerInfo, listenSwitch.peerInfo, listenSwitch.peerInfo]))
      check:
        proto3.messages.len == 10
        successResult.isOk
        successResult.value == 10

       
