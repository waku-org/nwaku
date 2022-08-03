{.used.}

import
  std/[unittest, options, tables, sets, times, os, strutils],
  chronicles,
  chronos,
  sqlite3_abi,
  stew/byteutils,
  ../../waku/v2/node/storage/message/waku_message_store,
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/utils/time,
  ../../waku/v2/utils/pagination,
  ./utils


suite "Message Store":
  test "set and get works":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      topic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic =  "/waku/2/default-waku/proto"

      t1 = getNanosecondTime(epochTime())
      t2 = getNanosecondTime(epochTime())
      t3 = high(int64)
    var msgs = @[
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic, version: uint32(0), timestamp: t1),
      WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic, version: uint32(1), timestamp: t2),
      WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: topic, version: high(uint32), timestamp: t3),
    ]

    defer: store.close()

    var indexes: seq[Index] = @[]
    for msg in msgs:
      var index = computeIndex(msg)
      let output = store.put(index, msg, pubsubTopic)
      check output.isOk
      indexes.add(index)


    # flags for version
    var v0Flag, v1Flag, vMaxFlag: bool = false
    # flags for sender timestamp
    var t1Flag, t2Flag, t3Flag: bool = false
    # flags for receiver timestamp
    var rt1Flag, rt2Flag, rt3Flag: bool = false
    # flags for message/pubsubTopic (default true)
    var msgFlag, psTopicFlag = true

    var responseCount = 0
    proc data(receiverTimestamp: Timestamp, msg: WakuMessage, psTopic: string) {.raises: [Defect].} =
      responseCount += 1

      # Note: cannot use `check` within `{.raises: [Defect].}` block:
      # @TODO: /Nim/lib/pure/unittest.nim(577, 16) Error: can raise an unlisted exception: Exception
      if msg notin msgs:
        msgFlag = false

      if psTopic != pubsubTopic:
        psTopicFlag = false

      # check the correct retrieval of versions
      if msg.version == uint32(0): v0Flag = true
      if msg.version == uint32(1): v1Flag = true
      # high(uint32) is the largest value that fits in uint32, this is to make sure there is no overflow in the storage
      if msg.version == high(uint32): vMaxFlag = true

      # check correct retrieval of sender timestamps
      if msg.timestamp == t1: t1Flag = true
      if msg.timestamp == t2: t2Flag = true
      if msg.timestamp == t3: t3Flag = true

      # check correct retrieval of receiver timestamps
      if receiverTimestamp == indexes[0].receiverTime: rt1Flag = true
      if receiverTimestamp == indexes[1].receiverTime: rt2Flag = true
      if receiverTimestamp == indexes[2].receiverTime: rt3Flag = true


    let res = store.getAll(data)
    
    check:
      res.isErr == false
      responseCount == 3
      # check version
      v0Flag == true
      v1Flag == true
      vMaxFlag == true
      # check sender timestamp
      t1Flag == true
      t2Flag == true
      t3Flag == true
      # check receiver timestamp
      rt1Flag == true
      rt2Flag == true
      rt3Flag == true
      # check messages and pubsubTopic
      msgFlag == true
      psTopicFlag == true
  test "set and get user version":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
    defer: store.close()

    let res = database.setUserVersion(5)
    check res.isErr == false

    let ver = database.getUserVersion()
    check:
      ver.isErr == false
      ver.value == 5
  test "migration":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
    defer: store.close()

    template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
    let migrationPath = sourceDir

    let res = database.migrate(migrationPath, 10)
    check:
      res.isErr == false

    let ver = database.getUserVersion()
    check:
      ver.isErr == false
      ver.value == 10

    test "number of messages retrieved by getAll is bounded by storeCapacity":
      let
        database = SqliteDatabase.init("", inMemory = true)[]
        contentTopic = ContentTopic("/waku/2/default-content/proto")
        pubsubTopic =  "/waku/2/default-waku/proto"
        capacity = 10
        store = WakuMessageStore.init(database, capacity)[]

      defer: store.close()

      for i in 1..capacity:
        let
          msg = WakuMessage(payload: @[byte i], contentTopic: contentTopic, version: uint32(0), timestamp: Timestamp(i))
          index = computeIndex(msg)
          output = store.put(index, msg, pubsubTopic)
        check output.isOk

      var
        responseCount = 0
        lastMessageTimestamp = Timestamp(0)

      proc data(receiverTimestamp: Timestamp, msg: WakuMessage, psTopic: string) {.raises: [Defect].} =
        responseCount += 1
        lastMessageTimestamp = msg.timestamp

      # Test limited getAll function when store is at capacity
      let resMax = store.getAll(data)
   
      check:
        resMax.isOk
        responseCount == capacity # We retrieved all items
        lastMessageTimestamp == Timestamp(capacity) # Returned rows were ordered correctly # TODO: not representative because the timestamp only has second resolution

    test "DB store capacity":
      let
        database = SqliteDatabase.init("", inMemory = true)[]
        contentTopic = ContentTopic("/waku/2/default-content/proto")
        pubsubTopic =  "/waku/2/default-waku/proto"
        capacity = 100
        overload = 65
        store = WakuMessageStore.init(database, capacity)[]

      defer: store.close()

      for i in 1..capacity+overload:
        let
          msg = WakuMessage(payload: ($i).toBytes(), contentTopic: contentTopic, version: uint32(0), timestamp: Timestamp(i))
          index = computeIndex(msg)
          output = store.put(index, msg, pubsubTopic)
        check output.isOk

      # count messages in DB
      var numMessages: int64
      proc handler(s: ptr sqlite3_stmt) =
        numMessages = sqlite3_column_int64(s, 0)
      let countQuery = "SELECT COUNT(*) FROM message" # the table name is set in a const in waku_message_store
      discard store.database.query(countQuery, handler)

      check:
        # expected number of messages is 120 because
        # (capacity = 100) + (half of the overflow window = 15) + (5 messages added after after the last delete)
        # the window size changes when changing `const maxStoreOverflow = 1.3 in waku_message_store
        numMessages == 120 


suite "Message Store: Retrieve Pages":
  setup:
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic =  "/waku/2/default-waku/proto"

      t1 = getNanosecondTime(epochTime())-800
      t2 = getNanosecondTime(epochTime())-700
      t3 = getNanosecondTime(epochTime())-600
      t4 = getNanosecondTime(epochTime())-500
      t5 = getNanosecondTime(epochTime())-400
      t6 = getNanosecondTime(epochTime())-300
      t7 = getNanosecondTime(epochTime())-200
      t8 = getNanosecondTime(epochTime())-100
      t9 = getNanosecondTime(epochTime())

    var msgs = @[
      WakuMessage(payload: @[byte 1], contentTopic: contentTopic, version: uint32(0), timestamp: t1),
      WakuMessage(payload: @[byte 2, 2, 3, 4], contentTopic: contentTopic, version: uint32(1), timestamp: t2),
      WakuMessage(payload: @[byte 3], contentTopic: contentTopic, version: uint32(2), timestamp: t3),
      WakuMessage(payload: @[byte 4], contentTopic: contentTopic, version: uint32(2), timestamp: t4),
      WakuMessage(payload: @[byte 5, 3, 5, 6], contentTopic: contentTopic, version: uint32(3), timestamp: t5),
      WakuMessage(payload: @[byte 6], contentTopic: contentTopic, version: uint32(3), timestamp: t6),
      WakuMessage(payload: @[byte 7], contentTopic: contentTopic, version: uint32(3), timestamp: t7),
      WakuMessage(payload: @[byte 8, 4, 6, 2, 1, 5, 6, 13], contentTopic: contentTopic, version: uint32(3), timestamp: t8),
      WakuMessage(payload: @[byte 9], contentTopic: contentTopic, version: uint32(3), timestamp: t9),
    ]

    var indexes: seq[Index] = @[]
    for msg in msgs:
      var index = computeIndex(msg)
      let output = store.put(index, msg, pubsubTopic)
      check output.isOk
      indexes.add(index)

  teardown:
    store.close()

  test "get forward page":
    let maxPageSize = 3'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: indexes[1],
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 3,
                             cursor: indexes[4],
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 3
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[k+2] == m # offset of two because we used the second message (indexes[1]) as cursor; the cursor is excluded in the returned page

  test "get backward page":
    let maxPageSize = 3'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: indexes[4],
                             direction: PagingDirection.BACKWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 3,
                             cursor: indexes[1],
                             direction: PagingDirection.BACKWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 3
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[^(k+6)] == m


  test "get forward page (default index)":
    let maxPageSize = 3'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             # we don't set an index here to test the default index
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 3,
                             cursor: indexes[2],
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 3
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[k] == m


  test "get backward page (default index)":
    let maxPageSize = 3'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             # we don't set an index here to test the default index
                             direction: PagingDirection.BACKWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 3,
                             cursor: indexes[6],
                             direction: PagingDirection.BACKWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 3
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[^(k+1)] == m


  test "get large forward page":
    let maxPageSize = 12'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             # we don't set an index here; start at the beginning
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 9, # there are only 10 msgs in total in the DB
                             cursor: indexes[8],
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 9
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[k] == m


  test "get large backward page":
    let maxPageSize = 12'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             # we don't set an index here to test the default index
                             direction: PagingDirection.BACKWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 9,
                             cursor: indexes[0],
                             direction: PagingDirection.BACKWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 9
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[^(k+1)] == m


  test "get filtered page, maxPageSize == number of matching messages":
    proc predicate (indMsg: IndexedWakuMessage): bool {.gcsafe, closure.} =
      # filter on timestamp
      if indMsg.msg.timestamp < t4 or indMsg.msg.timestamp > t6:
        return false

      return true

    let maxPageSize = 3'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: indexes[1],
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(predicate, pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 3,
                             cursor: indexes[5],
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 3
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[k+3] == m # offset of three because second message is the index, and the third message is not in the select time window

  test "get filtered page, maxPageSize > number of matching messages":
    proc predicate (indMsg: IndexedWakuMessage): bool {.gcsafe, closure.} =
      # filter on timestamp
      if indMsg.msg.timestamp < t4 or indMsg.msg.timestamp > t5:
        return false
      return true

    let maxPageSize = 3'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: indexes[1],
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(predicate, pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 2,
                             cursor: indexes[8], # index is advanced by one because one message was not accepted by the filter
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 2 # only two messages are in the time window going through the filter
      outPagingInfo == expectedOutPagingInfo

    for (k, m) in outMessages.pairs():
      check: msgs[k+3] == m # offset of three because second message is the index, and the third message is not in the select time window


  test "get page with index that is not in the DB":
    let maxPageSize = 3'u64

    let nonStoredMsg = WakuMessage(payload: @[byte 13], contentTopic: "hello", version: uint32(3), timestamp: getNanosecondTime(epochTime()))
    var nonStoredIndex = computeIndex(nonStoredMsg)

    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: nonStoredIndex,
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 0, # no message expected
                             cursor: Index(),
                             direction: PagingDirection.FORWARD)
    check:
      outError == HistoryResponseError.INVALID_CURSOR
      outMessages.len == 0 # only two messages are in the time window going through the filter
      outPagingInfo == expectedOutPagingInfo

  test "ask for last index, forward":
    let maxPageSize = 3'u64

    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: indexes[8],
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 0, # no message expected, because we already have the last index
                             cursor: Index(), # empty index, because we went beyond the last index
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.INVALID_CURSOR # TODO: clarify: should this index be valid?
      outMessages.len == 0 # no message expected, because we already have the last index
      outPagingInfo == expectedOutPagingInfo

  test "ask for first index, backward":
    let maxPageSize = 3'u64

    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: indexes[0],
                             direction: PagingDirection.BACKWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 0, # no message expected, because we already have the first index (and go trough backwards)
                             cursor: Index(), # empty index, because we went beyond the first index (backwards)
                             direction: PagingDirection.BACKWARD)

    check:
      outError == HistoryResponseError.INVALID_CURSOR # TODO: clarify: should this index be valid?
      outMessages.len == 0 # no message expected, because we already have the first index
      outPagingInfo == expectedOutPagingInfo



  test "valid index but no predicate matches":
    proc predicate (indMsg: IndexedWakuMessage): bool {.gcsafe, closure.} =
      return false

    let maxPageSize = 3'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             cursor: indexes[1],
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(predicate, pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 0,
                             cursor: indexes[8], # last index; DB was searched until the end (no message matched the predicate)
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 0 # predicate is false for each message
      outPagingInfo == expectedOutPagingInfo

  test "sparse filter (-> merging several DB pages into one reply page)":
    proc predicate (indMsg: IndexedWakuMessage): bool {.gcsafe, closure.} =
      if indMsg.msg.payload[0] mod 4 == 0:
        return true

    let maxPageSize = 2'u64
    let pagingInfo = PagingInfo(pageSize: maxPageSize,
                             # we don't set an index here, starting from the beginning. This also covers the inital special case of the retrieval loop.
                             direction: PagingDirection.FORWARD)
    let (outMessages, outPagingInfo, outError) = store.getPage(predicate, pagingInfo).get()

    let expectedOutPagingInfo = PagingInfo(pageSize: 2,
                             cursor: indexes[7],
                             direction: PagingDirection.FORWARD)

    check:
      outError == HistoryResponseError.NONE
      outMessages.len == 2
      outPagingInfo == expectedOutPagingInfo
      outMessages[0] == msgs[3]
      outMessages[1] == msgs[7]

test "Message Store: Retention Time": # TODO: better retention time test coverage
  let 
    database = SqliteDatabase.init("", inMemory = true)[]
    store = WakuMessageStore.init(database, isSqliteOnly=true, retentionTime=100)[]
    contentTopic = ContentTopic("/waku/2/default-content/proto")
    pubsubTopic =  "/waku/2/default-waku/proto"

    t1 = getNanosecondTime(epochTime())-300_000_000_000
    t2 = getNanosecondTime(epochTime())-200_000_000_000
    t3 = getNanosecondTime(epochTime())-100_000_000_000
    t4 = getNanosecondTime(epochTime())-50_000_000_000
    t5 = getNanosecondTime(epochTime())-40_000_000_000
    t6 = getNanosecondTime(epochTime())-3_000_000_000
    t7 = getNanosecondTime(epochTime())-2_000_000_000
    t8 = getNanosecondTime(epochTime())-1_000_000_000
    t9 = getNanosecondTime(epochTime())

  var msgs = @[
    WakuMessage(payload: @[byte 1], contentTopic: contentTopic, version: uint32(0), timestamp: t1),
    WakuMessage(payload: @[byte 2, 2, 3, 4], contentTopic: contentTopic, version: uint32(1), timestamp: t2),
    WakuMessage(payload: @[byte 3], contentTopic: contentTopic, version: uint32(2), timestamp: t3),
    WakuMessage(payload: @[byte 4], contentTopic: contentTopic, version: uint32(2), timestamp: t4),
    WakuMessage(payload: @[byte 5, 3, 5, 6], contentTopic: contentTopic, version: uint32(3), timestamp: t5),
    WakuMessage(payload: @[byte 6], contentTopic: contentTopic, version: uint32(3), timestamp: t6),
    WakuMessage(payload: @[byte 7], contentTopic: contentTopic, version: uint32(3), timestamp: t7),
    WakuMessage(payload: @[byte 8, 4, 6, 2, 1, 5, 6, 13], contentTopic: contentTopic, version: uint32(3), timestamp: t8),
    WakuMessage(payload: @[byte 9], contentTopic: contentTopic, version: uint32(3), timestamp: t9),
  ]

  var indexes: seq[Index] = @[]
  for msg in msgs:
    var index = computeIndex(msg, receivedTime = msg.timestamp)
    let output = store.put(index, msg, pubsubTopic)
    check output.isOk
    indexes.add(index)

  # let maxPageSize = 9'u64
  # let pagingInfo = PagingInfo(pageSize: maxPageSize,
  #                          direction: PagingDirection.FORWARD)
  # let (outMessages, outPagingInfo, outError) = store.getPage(pagingInfo).get()

  # let expectedOutPagingInfo = PagingInfo(pageSize: 7,
  #                          cursor: indexes[8],
  #                          direction: PagingDirection.FORWARD)

  # check:
  #   outError == HistoryResponseError.NONE
  #   outMessages.len == 7
  #   outPagingInfo == expectedOutPagingInfo

  # for (k, m) in outMessages.pairs():
  #   check: msgs[k+2] == m # offset of two because the frist two messages got deleted

  # store.close()

   
