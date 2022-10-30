{.used.}

import
  std/[unittest, options, sequtils],
  stew/byteutils,
  chronos
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/storage/message/sqlite_store,
  ../../waku/v2/node/storage/message/message_retention_policy,
  ../../waku/v2/node/storage/message/message_retention_policy_capacity,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store/pagination,
  ../../waku/v2/utils/time,
  ./utils,
  ./testlib/common


proc newTestDatabase(): SqliteDatabase =
  SqliteDatabase.new(":memory:").tryGet()


suite "SQLite message store - init store":
  test "init store":
    ## Given
    let database = newTestDatabase()
    
    ## When
    let resStore = SqliteStore.init(database)

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

    ## When
    let resPut = store.put(DefaultPubsubTopic, message)

    ## Then
    check:
      resPut.isOk() 
    
    let storedMsg = store.getAllMessages().tryGet()
    check:
      storedMsg.len == 1
      storedMsg.all do (item: auto) -> bool:
        let (pubsubTopic, msg, digest, storeTimestamp) = item
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
      store = SqliteStore.init(database).tryGet()
      retentionPolicy: MessageRetentionPolicy = CapacityRetentionPolicy.init(capacity=storeCapacity)

    let messages = @[
      fakeWakuMessage(ts=ts(0)),
      fakeWakuMessage(ts=ts(1)),

      fakeWakuMessage(contentTopic=contentTopic, ts=ts(2)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(3)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(4)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(5)),
      fakeWakuMessage(contentTopic=contentTopic, ts=ts(6))
    ]

    ## When
    for msg in messages:
      require store.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()
      require retentionPolicy.execute(store).isOk()

    ## Then
    let storedMsg = store.getAllMessages().tryGet()
    check:
      storedMsg.len == storeCapacity
      storedMsg.all do (item: auto) -> bool:
        let (pubsubTopic, msg, digest, storeTimestamp) = item
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

    let
      t1 = ts(0)
      t2 = ts(1)
      t3 = high(int64)

    var msgs = @[
      WakuMessage(payload: @[byte 1, 2, 3], contentTopic: DefaultContentTopic, version: uint32(0), timestamp: t1),
      WakuMessage(payload: @[byte 1, 2, 3, 4], contentTopic: DefaultContentTopic, version: uint32(1), timestamp: t2),
      # high(uint32) is the largest value that fits in uint32, this is to make sure there is no overflow in the storage
      WakuMessage(payload: @[byte 1, 2, 3, 4, 5], contentTopic: DefaultContentTopic, version: high(uint32), timestamp: t3),
    ]

    var indexes: seq[PagingIndex] = @[]
    for msg in msgs:
      require store.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()

      let index = PagingIndex.compute(msg, msg.timestamp, DefaultPubsubTopic)
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

    for (pubsubTopic, msg, digest, receiverTimestamp) in result:
      check:
        pubsubTopic == DefaultPubsubTopic

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
  
  # TODO: Move this test case to retention policy test suite
  test "number of messages retrieved by getAll is bounded by storeCapacity":
    let capacity = 10

    let
      database = newTestDatabase()
      store = SqliteStore.init(database).tryGet()
      retentionPolicy: MessageRetentionPolicy = CapacityRetentionPolicy.init(capacity=capacity)

    for i in 1..capacity:
      let msg = WakuMessage(payload: @[byte i], contentTopic: DefaultContentTopic, version: 0, timestamp: Timestamp(i))
      require store.put(DefaultPubsubTopic, msg, computeDigest(msg), msg.timestamp).isOk()
      require retentionPolicy.execute(store).isOk()
      
    ## Then
    # Test limited getAll function when store is at capacity
    let resMax = store.getAllMessages()
    check:
      resMax.isOk()
    
    let response = resMax.tryGet()
    let lastMessageTimestamp = response[^1][1].timestamp
    check:
      response.len == capacity # We retrieved all items
      lastMessageTimestamp == Timestamp(capacity) # Returned rows were ordered correctly # TODO: not representative because the timestamp only has second resolution

    ## Cleanup
    store.close()

  # TODO: Move this test case to retention policy test suite
  test "DB store capacity":
    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic =  "/waku/2/default-waku/proto"
      capacity = 100
      overload = 65

    let
      database = newTestDatabase()
      store = SqliteStore.init(database).tryGet()
      retentionPolicy: MessageRetentionPolicy = CapacityRetentionPolicy.init(capacity=capacity)

    for i in 1..capacity+overload:
      let msg = WakuMessage(payload: ($i).toBytes(), contentTopic: contentTopic, version: uint32(0), timestamp: Timestamp(i))
      require store.put(pubsubTopic, msg).isOk()
      require retentionPolicy.execute(store).isOk()

    # count messages in DB
    let numMessages = store.getMessagesCount().tryGet()
    check:
      # expected number of messages is 120 because
      # (capacity = 100) + (half of the overflow window = 15) + (5 messages added after after the last delete)
      # the window size changes when changing `const maxStoreOverflow = 1.3 in sqlite_store
      numMessages == 120 

    ## Teardown
    store.close()