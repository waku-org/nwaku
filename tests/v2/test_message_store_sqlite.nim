{.used.}

import
  std/[unittest, options, tables, sets, times, strutils, sequtils, os],
  stew/byteutils,
  chronos,
  chronicles,
  sqlite3_abi
import
  ../../waku/v2/node/storage/message/sqlite_store,
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

proc getTestTimestamp(offset=0): Timestamp = 
  Timestamp(getNanosecondTime(epochTime()))

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


suite "SQLite message store - init store":
  test "init store":
    ## Given
    const storeCapacity = 20

    let database = newTestDatabase()
    
    ## When
    let 
      retentionPolicy: MessageRetentionPolicy = CapacityRetentionPolicy.init(capacity=storeCapacity)
      resStore = SqliteStore.init(database, retentionPolicy=some(retentionPolicy))

    ## Then
    check:
      resStore.isOk()
    
    let store = resStore.tryGet()
    check:
      not store.isNil()

    ## Teardown
    store.close()

  test "init store with prepopulated database with messages older than retention policy":
    # TODO: Implement initialization test cases
    discard

  test "init store with prepopulated database with messsage count greater than max capacity":
    # TODO: Implement initialization test cases
    discard
  

# TODO: Add test cases to cover the store retention time fucntionality
suite "SQLite message store - insert messages":
  test "insert a message":
    ## Given
    const contentTopic = "test-content-topic"

    let 
      database = newTestDatabase()
      store = SqliteStore.init(database).tryGet()

    let message = fakeWakuMessage(contentTopic=contentTopic)
    let messageIndex = Index.compute(message, getNanosecondTime(epochTime()), DefaultPubsubTopic)

    ## When
    let resPut = store.put(messageIndex, message, DefaultPubsubTopic)

    ## Then
    check:
      resPut.isOk() 
    
    let storedMsg = store.getAllMessages().tryGet()
    check:
      storedMsg.len == 1
      storedMsg.all do (item: auto) -> bool:
        let (_, msg, pubsubTopic) = item
        msg.contentTopic == contentTopic and
        pubsubTopic == DefaultPubsubTopic
    
    ## Teardown
    store.close()

  test "store capacity should be limited":
    ## Given
    const storeCapacity = 5
    const contentTopic = "test-content-topic"

    let 
      database = newTestDatabase()
      retentionPolicy: MessageRetentionPolicy = CapacityRetentionPolicy.init(capacity=storeCapacity)
      store = SqliteStore.init(database, retentionPolicy=some(retentionPolicy)).tryGet()

    let messages = @[
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 0),
      fakeWakuMessage(ts=getNanosecondTime(epochTime()) + 1),

      fakeWakuMessage(contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 2),
      fakeWakuMessage(contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 3),
      fakeWakuMessage(contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 4),
      fakeWakuMessage(contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 5),
      fakeWakuMessage(contentTopic=contentTopic, ts=getNanosecondTime(epochTime()) + 6)
    ]

    ## When
    for msg in messages:
      let index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, DefaultPubsubTopic)
      require(resPut.isOk())

    ## Then
    let storedMsg = store.getAllMessages().tryGet()
    check:
      storedMsg.len == storeCapacity
      storedMsg.all do (item: auto) -> bool:
        let (_, msg, pubsubTopic) = item
        msg.contentTopic == contentTopic and
        pubsubTopic == DefaultPubsubTopic

    ## Teardown
    store.close()


# TODO: Review the following suite test cases
suite "Message Store":
  test "set and get works":
    ## Given
    let 
      database = newTestDatabase()
      store = SqliteStore.init(database).get()
      topic = DefaultContentTopic
      pubsubTopic = DefaultPubsubTopic

      t1 = getTestTimestamp(0)
      t2 = getTestTimestamp(1)
      t3 = high(int64)

    var msgs = @[
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic, version: uint32(0), timestamp: t1),
      WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: topic, version: uint32(1), timestamp: t2),
      # high(uint32) is the largest value that fits in uint32, this is to make sure there is no overflow in the storage
      WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: topic, version: high(uint32), timestamp: t3),
    ]

    var indexes: seq[Index] = @[]
    for msg in msgs:
      var index = Index.compute(msg, msg.timestamp, DefaultPubsubTopic)
      let resPut = store.put(index, msg, pubsubTopic)
      require resPut.isOk
      indexes.add(index)

    ## When
    let res = store.getAllMessages()

    ## Then
    check:
      res.isOk()

    let result = res.value
    check:
      result.len == 3
    
    # flags for version
    var v0Flag, v1Flag, vMaxFlag: bool = false
    # flags for sender timestamp
    var t1Flag, t2Flag, t3Flag: bool = false
    # flags for receiver timestamp
    var rt1Flag, rt2Flag, rt3Flag: bool = false

    for (receiverTimestamp, msg, psTopic) in result:
      # check correct retrieval of receiver timestamps
      if receiverTimestamp == indexes[0].receiverTime: rt1Flag = true
      if receiverTimestamp == indexes[1].receiverTime: rt2Flag = true
      if receiverTimestamp == indexes[2].receiverTime: rt3Flag = true

      check:
        msg in msgs

      # check the correct retrieval of versions
      if msg.version == uint32(0): v0Flag = true
      if msg.version == uint32(1): v1Flag = true
      if msg.version == high(uint32): vMaxFlag = true

      # check correct retrieval of sender timestamps
      if msg.timestamp == t1: t1Flag = true
      if msg.timestamp == t2: t2Flag = true
      if msg.timestamp == t3: t3Flag = true

      check:
        psTopic == pubSubTopic
    
    check:
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

    ## Cleanup
    store.close()
  
  test "set and get user version":
    ## Given
    let 
      database = newTestDatabase()
      store = SqliteStore.init(database).get()

    ## When
    let resSetVersion = database.setUserVersion(5)
    let resGetVersion = database.getUserVersion()
    
    ## Then
    check:
      resSetVersion.isOk()
      resGetVersion.isOk()
    
    let version = resGetVersion.tryGet()
    check:
      version == 5

    ## Cleanup
    store.close()
  
  test "migration":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = SqliteStore.init(database)[]
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
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic =  "/waku/2/default-waku/proto"
      capacity = 10

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      retentionPolicy: MessageRetentionPolicy = CapacityRetentionPolicy.init(capacity=capacity)
      store = SqliteStore.init(database, retentionPolicy=some(retentionPolicy)).tryGet()


    for i in 1..capacity:
      let
        msg = WakuMessage(payload: @[byte i], contentTopic: contentTopic, version: uint32(0), timestamp: Timestamp(i))
        index = Index.compute(msg, getTestTimestamp(), DefaultPubsubTopic)
        output = store.put(index, msg, pubsubTopic)
      check output.isOk

    # Test limited getAll function when store is at capacity
    let resMax = store.getAllMessages()

    ## THen
    check:
      resMax.isOk()
    
    let response = resMax.tryGet()
    let lastMessageTimestamp = response[^1][1].timestamp
    check:
      response.len == capacity # We retrieved all items
      lastMessageTimestamp == Timestamp(capacity) # Returned rows were ordered correctly # TODO: not representative because the timestamp only has second resolution

    ## Cleanup
    store.close()

  test "DB store capacity":
    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic =  "/waku/2/default-waku/proto"
      capacity = 100
      overload = 65

    let
      database = SqliteDatabase.init("", inMemory = true)[]
      retentionPolicy: MessageRetentionPolicy = CapacityRetentionPolicy.init(capacity=capacity)
      store = SqliteStore.init(database, retentionPolicy=some(retentionPolicy)).tryGet()
    defer: store.close()

    for i in 1..capacity+overload:
      let
        msg = WakuMessage(payload: ($i).toBytes(), contentTopic: contentTopic, version: uint32(0), timestamp: Timestamp(i))
        index = Index.compute(msg, getTestTimestamp(), DefaultPubsubTopic)
        output = store.put(index, msg, pubsubTopic)
      check output.isOk

    # count messages in DB
    var numMessages: int64
    proc handler(s: ptr sqlite3_stmt) =
      numMessages = sqlite3_column_int64(s, 0)
    let countQuery = "SELECT COUNT(*) FROM message" # the table name is set in a const in sqlite_store
    discard database.query(countQuery, handler)

    check:
      # expected number of messages is 120 because
      # (capacity = 100) + (half of the overflow window = 15) + (5 messages added after after the last delete)
      # the window size changes when changing `const maxStoreOverflow = 1.3 in sqlite_store
      numMessages == 120 