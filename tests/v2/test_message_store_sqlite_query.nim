{.used.}

import
  std/[options, tables, sets, times, strutils, sequtils],
  stew/byteutils,
  unittest2,
  chronos,
  chronicles,
  ../../waku/v2/node/storage/message/waku_message_store,
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/utils/time,
  ../../waku/v2/utils/pagination,
  ./utils


const 
  DefaultPubsubTopic = "/waku/2/default-waku/proto"
  DefaultContentTopic = ContentTopic("/waku/2/default-content/proto")


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.init("", inMemory = true).tryGet()

proc fakeWakuMessage(
  payload = "TEST-PAYLOAD",
  contentTopic = DefaultContentTopic, 
  ts = getNanosecondTime(epochTime())
): WakuMessage = 
  WakuMessage(
    payload: toBytes(payload),
    contentTopic: contentTopic,
    version: 1,
    timestamp: ts
  )


suite "message store - history query":

  test "single content topic":
    ## Given
    const storeCapacity = 20
    const contentTopic = "test-content-topic"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),

      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 3),

      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 5),
      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 6),
      fakeWakuMessage("MSG-06", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 7),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages[2..3]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()
  
  test "single content topic and descending order":
    ## Given
    const storeCapacity = 20
    const contentTopic = "test-content-topic"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),

      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 3),
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 5),
      
      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 6),
      fakeWakuMessage("MSG-06", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 7),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      maxPageSize=2,
      ascendingOrder=false
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages[6..7]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()

  test "multiple content topic":
    ## Given
    const storeCapacity = 20
    const contentTopic1 = "test-content-topic-1"
    const contentTopic2 = "test-content-topic-2"
    const contentTopic3 = "test-content-topic-3"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),

      fakeWakuMessage("MSG-01", contentTopic=contentTopic1, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic2, ts=getNanosecondTime(epochTime()) + 3),

      fakeWakuMessage("MSG-03", contentTopic=contentTopic3, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic1, ts=getNanosecondTime(epochTime()) + 5),
      fakeWakuMessage("MSG-05", contentTopic=contentTopic2, ts=getNanosecondTime(epochTime()) + 6),
      fakeWakuMessage("MSG-06", contentTopic=contentTopic3, ts=getNanosecondTime(epochTime()) + 7),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic1, contentTopic2]),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic in @[contentTopic1, contentTopic2]
      filteredMessages == messages[2..3]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()
  
  test "content topic and pubsub topic":
    ## Given
    const storeCapacity = 20
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages1 = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),

      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 3),
    ]
    for msg in messages1:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())

    let messages2 = @[
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 5),
      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 6),
      fakeWakuMessage("MSG-06", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 7),
    ]
    for msg in messages2:
      let index = Index.compute(msg, msg.timestamp, pubsubTopic)
      let resPut = store.put(index, msg, pubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      pubsubTopic=some(pubsubTopic),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages2[0..1]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()

  test "content topic and cursor":
    ## Given
    const storeCapacity = 20
    const contentTopic = "test-content-topic"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),

      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 3),

      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 5),
      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 6),
      fakeWakuMessage("MSG-06", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 7),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())

    let cursor = Index.compute(messages[4], messages[4].timestamp, DefaultPubsubTopic)
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      cursor=some(cursor),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages[5..6]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()

  test "content topic, cursor and descending order":
    ## Given
    const storeCapacity = 20
    const contentTopic = "test-content-topic"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),

      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 3),
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 5),

      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 6),
      fakeWakuMessage("MSG-06", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 7),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())

    let cursor = Index.compute(messages[6], messages[6].timestamp, DefaultPubsubTopic)
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      cursor=some(cursor),
      maxPageSize=2,
      ascendingOrder=false
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages[4..5]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()

  test "content topic, pubsub topic and cursor":
    ## Given
    const storeCapacity = 20
    const contentTopic = "test-content-topic"
    const pubsubTopic = "test-pubsub-topic"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages1 = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),
      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 3),
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 4),
    ]
    for msg in messages1:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())

    let messages2 = @[
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 5),
      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 6),
      fakeWakuMessage("MSG-06", contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 7),
    ]
    for msg in messages2:
      let index = Index.compute(msg, msg.timestamp, pubsubTopic)
      let resPut = store.put(index, msg, pubsubTopic)
      require(resPut.isOk())

    let cursor = Index.compute(messages2[0], messages2[0].timestamp, DefaultPubsubTopic)
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      pubsubTopic=some(pubsubTopic),
      cursor=some(cursor),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages2[0..1]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()

  test "single content topic - no results":
    ## Given
    const storeCapacity = 10
    const contentTopic = "test-content-topic"

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage("MSG-01", contentTopic=DefaultContentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage("MSG-02", contentTopic=DefaultContentTopic, ts=getNanosecondTime(epochTime()) + 3),
      fakeWakuMessage("MSG-03", contentTopic=DefaultContentTopic, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage("MSG-04", contentTopic=DefaultContentTopic, ts=getNanosecondTime(epochTime()) + 5),
      fakeWakuMessage("MSG-05", contentTopic=DefaultContentTopic, ts=getNanosecondTime(epochTime()) + 6),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      maxPageSize=2,
      ascendingOrder=true
    )

    ## Then
    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 0
      pagingInfo.isNone()
    
    ## Teardown
    store.close()
  
  test "single content topic and valid time range":
    ## Given
    let 
      storeCapacity = 10
      contentTopic = "test-content-topic"
      timeOrigin = getNanosecondTime(epochTime())

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=timeOrigin + 00),
      
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=timeOrigin + 10),
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=timeOrigin + 20),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=timeOrigin + 30),

      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=timeOrigin + 50),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      startTime=some(timeOrigin + 5),
      endTime=some(timeOrigin + 35),
      maxPageSize=2,
      ascendingOrder=true
    )

    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 2
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages[1..2]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()
  
  test "single content topic and invalid time range - no results":
    ## Given
    let 
      storeCapacity = 10
      contentTopic = "test-content-topic"
      timeOrigin = getNanosecondTime(epochTime())

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=timeOrigin + 00),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=timeOrigin + 10),
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=timeOrigin + 20),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=timeOrigin + 30),
      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=timeOrigin + 50),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      startTime=some(timeOrigin + 35),
      endTime=some(timeOrigin + 10),
      maxPageSize=2,
      ascendingOrder=true
    )

    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 0
      pagingInfo.isNone()
    
    ## Teardown
    store.close()
  
  test "single content topic and only time range start":
    ## Given
    let 
      storeCapacity = 10
      contentTopic = "test-content-topic"
      timeOrigin = getNanosecondTime(epochTime())

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=timeOrigin + 00),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=timeOrigin + 10),
      
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=timeOrigin + 20),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=timeOrigin + 30),
      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=timeOrigin + 50),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())
    
    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      startTime=some(timeOrigin + 15),
      ascendingOrder=false
    )

    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 3
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == messages[2..4]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()
  
  test "single content topic, cursor and only time range start":
    ## Given
    let 
      storeCapacity = 10
      contentTopic = "test-content-topic"
      timeOrigin = getNanosecondTime(epochTime())

    let 
      database = newTestDatabase()
      store = WakuMessageStore.init(database, capacity=storeCapacity).tryGet()

    let messages = @[
      fakeWakuMessage("MSG-01", contentTopic=contentTopic, ts=timeOrigin + 00),
      fakeWakuMessage("MSG-02", contentTopic=contentTopic, ts=timeOrigin + 10),
      
      fakeWakuMessage("MSG-03", contentTopic=contentTopic, ts=timeOrigin + 20),
      fakeWakuMessage("MSG-04", contentTopic=contentTopic, ts=timeOrigin + 30),

      fakeWakuMessage("MSG-05", contentTopic=contentTopic, ts=timeOrigin + 50),
    ]

    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())

    let cursor = Index.compute(messages[3], messages[3].timestamp, DefaultPubsubTopic)

    ## When
    let res = store.getMessagesByHistoryQuery(
      contentTopic=some(@[contentTopic]),
      cursor=some(cursor),
      startTime=some(timeOrigin + 15),
      maxPageSize=2,
      ascendingOrder=true
    )

    check:
      res.isOk()

    let (filteredMessages, pagingInfo) = res.tryGet()
    check:
      filteredMessages.len == 1
      filteredMessages.all do (msg: WakuMessage) -> bool:
        msg.contentTopic == contentTopic
      filteredMessages == @[messages[^1]]

    check:
      pagingInfo.isSome()
    
    ## Teardown
    store.close()
