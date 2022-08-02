{.used.}

import
  std/[options, tables, sets, sequtils],
  chronos, 
  chronicles,
  testutils/unittests, 
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/rpc/message
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/node/storage/message/waku_message_store,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/pagination,
  ../../waku/v2/utils/time,
  ../test_helpers, 
  ./utils

procSuite "Waku Store":
  const defaultContentTopic = ContentTopic("1")
  
  asyncTest "handle query":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      topic = defaultContentTopic
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic("2"))

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: topic)])

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    await proto.handleMessage("foo", msg)
    await proto.handleMessage("foo", msg2)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 1
        response.messages[0] == msg
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

  asyncTest "handle query with multiple content filters":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      topic1 = defaultContentTopic
      topic2 = ContentTopic("2")
      topic3 = ContentTopic("3")
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic1)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic2)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic3)

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: topic1), HistoryContentFilter(contentTopic: topic3)])

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    await proto.handleMessage("foo", msg1)
    await proto.handleMessage("foo", msg2)
    await proto.handleMessage("foo", msg3)

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

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())
  
  asyncTest "handle query with pubsub topic filter":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      contentTopic1 = defaultContentTopic
      contentTopic2 = ContentTopic("2")
      contentTopic3 = ContentTopic("3")
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic1)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic2)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic3)

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      pubsubtopic1 = "queried topic"
      pubsubtopic2 = "non queried topic"
      # this query targets: pubsubtopic1 AND (contentTopic1 OR contentTopic3)    
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: contentTopic1), HistoryContentFilter(contentTopic: contentTopic3)], pubsubTopic: pubsubTopic1)

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    # publish messages
    await proto.handleMessage(pubsubtopic1, msg1)
    await proto.handleMessage(pubsubtopic2, msg2)
    await proto.handleMessage(pubsubtopic2, msg3)

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

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

  asyncTest "handle query with pubsub topic filter with no match":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)
      msg3 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      pubsubtopic1 = "queried topic"
      pubsubtopic2 = "non queried topic"
      # this query targets: pubsubtopic1  
      rpc = HistoryQuery(pubsubTopic: pubsubTopic1)

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    # publish messages
    await proto.handleMessage(pubsubtopic2, msg1)
    await proto.handleMessage(pubsubtopic2, msg2)
    await proto.handleMessage(pubsubtopic2, msg3)

    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        response.messages.len() == 0
      completionFut.complete(true)

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

  asyncTest "handle query with pubsub topic filter matching the entire stored messages":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      msg1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: defaultContentTopic)
      msg2 = WakuMessage(payload: @[byte 4, 5, 6], contentTopic: defaultContentTopic)
      msg3 = WakuMessage(payload: @[byte 7, 8, 9,], contentTopic: defaultContentTopic)

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      pubsubtopic = "queried topic"
      # this query targets: pubsubtopic 
      rpc = HistoryQuery(pubsubTopic: pubsubtopic)

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    # publish messages
    await proto.handleMessage(pubsubtopic, msg1)
    await proto.handleMessage(pubsubtopic, msg2)
    await proto.handleMessage(pubsubtopic, msg3)

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

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

  asyncTest "handle query with store and restarts":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
      topic = defaultContentTopic
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      msg2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic("2"))

    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: topic)])

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    await proto.handleMessage("foo", msg)
    await sleepAsync(1.millis)  # Sleep a millisecond to ensure messages are stored chronologically
    await proto.handleMessage("foo", msg2)

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
    await listenSwitch2.start()

    proto2.setPeer(listenSwitch2.peerInfo.toRemotePeerInfo())

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
    
    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

  asyncTest "handle query with forward pagination":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
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
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)
      rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: defaultContentTopic)], pagingInfo: PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD) )
      
    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      await proto.handleMessage("foo", wakuMsg)
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

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

  asyncTest "handle query with backward pagination":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
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
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      await proto.handleMessage("foo", wakuMsg)
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

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

  asyncTest "handle queries with no paging info (auto-paginate)":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(key)
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
    await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      await proto.handleMessage("foo", wakuMsg)
      await sleepAsync(1.millis)  # Sleep a millisecond to ensure messages are stored chronologically
    var completionFut = newFuture[bool]()

    proc handler(response: HistoryResponse) {.gcsafe, closure.} =
      check:
        ## No pagination specified. Response will be auto-paginated with
        ## up to MaxPageSize messages per page.
        response.messages.len() == 8
        response.pagingInfo.pageSize == 8
        response.pagingInfo.direction == PagingDirection.BACKWARD
        response.pagingInfo.cursor != Index()
      completionFut.complete(true)

    let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: defaultContentTopic)] )

    await proto.query(rpc, handler)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    # free resources
    await allFutures(dialSwitch.stop(),
      listenSwitch.stop())

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
      query = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: defaultContentTopic), HistoryContentFilter(contentTopic: defaultContentTopic)], pagingInfo: pagingInfo, startTime: Timestamp(10), endTime: Timestamp(11))
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
      res = HistoryResponse(messages: @[wm], pagingInfo:pagingInfo, error: HistoryResponseError.INVALID_CURSOR)
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
      peer = PeerInfo.new(key)
      key2 = PrivateKey.random(ECDSA, rng[]).get()
      # peer2 = PeerInfo.new(key2)
    var
      msgList = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: Timestamp(0)),
        WakuMessage(payload: @[byte 1],contentTopic: ContentTopic("1"), timestamp: Timestamp(1)),
        WakuMessage(payload: @[byte 2],contentTopic: ContentTopic("2"), timestamp: Timestamp(2)),
        WakuMessage(payload: @[byte 3],contentTopic: ContentTopic("1"), timestamp: Timestamp(3)),
        WakuMessage(payload: @[byte 4],contentTopic: ContentTopic("2"), timestamp: Timestamp(4)),
        WakuMessage(payload: @[byte 5],contentTopic: ContentTopic("1"), timestamp: Timestamp(5)),
        WakuMessage(payload: @[byte 6],contentTopic: ContentTopic("2"), timestamp: Timestamp(6)),
        WakuMessage(payload: @[byte 7],contentTopic: ContentTopic("1"), timestamp: Timestamp(7)),
        WakuMessage(payload: @[byte 8],contentTopic: ContentTopic("2"), timestamp: Timestamp(8)),
        WakuMessage(payload: @[byte 9],contentTopic: ContentTopic("1"),timestamp: Timestamp(9))]

      msgList2 = @[WakuMessage(payload: @[byte 0], contentTopic: ContentTopic("2"), timestamp: Timestamp(0)),
        WakuMessage(payload: @[byte 11],contentTopic: ContentTopic("1"), timestamp: Timestamp(1)),
        WakuMessage(payload: @[byte 12],contentTopic: ContentTopic("2"), timestamp: Timestamp(2)),
        WakuMessage(payload: @[byte 3],contentTopic: ContentTopic("1"), timestamp: Timestamp(3)),
        WakuMessage(payload: @[byte 4],contentTopic: ContentTopic("2"), timestamp: Timestamp(4)),
        WakuMessage(payload: @[byte 5],contentTopic: ContentTopic("1"), timestamp: Timestamp(5)),
        WakuMessage(payload: @[byte 13],contentTopic: ContentTopic("2"), timestamp: Timestamp(6)),
        WakuMessage(payload: @[byte 14],contentTopic: ContentTopic("1"), timestamp: Timestamp(7))]

    #--------------------
    # setup default test store
    #--------------------
    var dialSwitch = newStandardSwitch()
    await dialSwitch.start()

    # to be connected to
    var listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      proto = WakuStore.init(PeerManager.new(dialSwitch), crypto.newRng(), store)

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

    listenSwitch.mount(proto)

    for wakuMsg in msgList:
      # the pubsub topic should be DefaultTopic
      await proto.handleMessage(DefaultTopic, wakuMsg)

    #--------------------
    # setup 2nd test store
    #--------------------
    var dialSwitch2 = newStandardSwitch()
    await dialSwitch2.start()

    # to be connected to
    var listenSwitch2 = newStandardSwitch(some(key2))
    await listenSwitch2.start()

    let
      database2 = SqliteDatabase.init("", inMemory = true)[]
      store2 = WakuMessageStore.init(database2)[]
      proto2 = WakuStore.init(PeerManager.new(dialSwitch2), crypto.newRng(), store2)

    proto2.setPeer(listenSwitch2.peerInfo.toRemotePeerInfo())

    listenSwitch2.mount(proto2)

    for wakuMsg in msgList2:
      # the pubsub topic should be DefaultTopic
      await proto2.handleMessage(DefaultTopic, wakuMsg)
    
    asyncTest "handle temporal history query with a valid time window":
      var completionFut = newFuture[bool]()

      proc handler(response: HistoryResponse) {.gcsafe, closure.} =
        check:
          response.messages.len() == 2
          response.messages.anyIt(it.timestamp == Timestamp(3))
          response.messages.anyIt(it.timestamp == Timestamp(5))
        completionFut.complete(true)

      let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], startTime: Timestamp(2), endTime: Timestamp(5))
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

      let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], startTime: Timestamp(2), endTime: Timestamp(2))
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
      let rpc = HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: ContentTopic("1"))], startTime: Timestamp(5), endTime: Timestamp(2))
      await proto.query(rpc, handler)

      check:
        (await completionFut.withTimeout(5.seconds)) == true

    asyncTest "resume message history":
      # starts a new node
      var dialSwitch3 = newStandardSwitch()
      await dialSwitch3.start()

      let
        database3 = SqliteDatabase.init("", inMemory = true)[]
        store3 = WakuMessageStore.init(database3)[]
        proto3 = WakuStore.init(PeerManager.new(dialSwitch3), crypto.newRng(), store3)

      proto3.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())

      let successResult = await proto3.resume()
      check:
        successResult.isOk
        successResult.value == 10
        proto3.messages.len == 10

      await dialSwitch3.stop()

    asyncTest "queryFrom":

      var completionFut = newFuture[bool]()

      proc handler(response: HistoryResponse) {.gcsafe, closure.} =
        check:
          response.messages.len() == 4
        completionFut.complete(true)

      let rpc = HistoryQuery(startTime: Timestamp(2), endTime: Timestamp(5))
      let successResult = await proto.queryFrom(rpc, handler, listenSwitch.peerInfo.toRemotePeerInfo())

      check:
        (await completionFut.withTimeout(5.seconds)) == true
        successResult.isOk
        successResult.value == 4

    asyncTest "queryFromWithPaging with empty pagingInfo":

      let rpc = HistoryQuery(startTime: Timestamp(2), endTime: Timestamp(5))

      let messagesResult = await proto.queryFromWithPaging(rpc, listenSwitch.peerInfo.toRemotePeerInfo())

      check:
        messagesResult.isOk
        messagesResult.value.len == 4

    asyncTest "queryFromWithPaging with pagination":
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

      var offListenSwitch = newStandardSwitch(some(PrivateKey.random(ECDSA, rng[]).get()))

      # starts a new node
      var dialSwitch3 = newStandardSwitch()
      await dialSwitch3.start()

      let
        database3 = SqliteDatabase.init("", inMemory = true)[]
        store3 = WakuMessageStore.init(database3)[]
        proto3 = WakuStore.init(PeerManager.new(dialSwitch3), crypto.newRng(), store3)

      let successResult = await proto3.resume(some(@[offListenSwitch.peerInfo.toRemotePeerInfo(),
                                                     listenSwitch.peerInfo.toRemotePeerInfo(),
                                                     listenSwitch2.peerInfo.toRemotePeerInfo()]))
      check:
        # `proto3` is expected to retrieve 14 messages because:
        # - the store mounted on `listenSwitch` holds 10 messages (`msgList`)
        # - the store mounted on `listenSwitch2` holds 7 messages (see `msgList2`)
        # - both stores share 3 messages, resulting in 14 unique messages in total
        proto3.messages.len == 14
        successResult.isOk
        successResult.value == 14

      #free resources
      await allFutures(dialSwitch3.stop(),
        offListenSwitch.stop())

    #free resources
    await allFutures(dialSwitch.stop(),
      dialSwitch2.stop(),
      listenSwitch.stop())


  asyncTest "limit store capacity":
    let
      capacity = 10
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic = "/waku/2/default-waku/proto"

    let store = WakuStore.init(PeerManager.new(newStandardSwitch()), crypto.newRng(), capacity = capacity)

    for i in 1..capacity:
      await store.handleMessage(pubsubTopic, WakuMessage(payload: @[byte i], contentTopic: contentTopic, timestamp: Timestamp(i)))
      await sleepAsync(1.millis)  # Sleep a millisecond to ensure messages are stored chronologically

    check:
      store.messages.len == capacity # Store is at capacity

    # Test that capacity holds
    await store.handleMessage(pubsubTopic, WakuMessage(payload: @[byte (capacity + 1)], contentTopic: contentTopic, timestamp: Timestamp(capacity + 1)))

    check:
      store.messages.len == capacity # Store is still at capacity
      store.messages.last().get().msg.payload == @[byte (capacity + 1)] # Simple check to verify last added item is stored
