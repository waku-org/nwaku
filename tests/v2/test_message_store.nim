{.used.}

import
  std/[unittest, options, tables, sets, times],
  chronos, chronicles,
  sqlite3_abi,
  ../../waku/v2/node/storage/message/waku_message_store,
  ../../waku/v2/node/storage/sqlite,
  ../../waku/v2/protocol/waku_store/waku_store,
  ./utils

template checkExec(s: ptr sqlite3_stmt) =
  if (let x = sqlite3_step(s); x != SQLITE_DONE):
    discard sqlite3_finalize(s)
    return err($sqlite3_errstr(x))

  if (let x = sqlite3_finalize(s); x != SQLITE_OK):
    return err($sqlite3_errstr(x))

template checkExec(q: string) =
  let s = prepare(q): discard
  checkExec(s)

suite "Message Store":
  test "set and get works":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
      topic = ContentTopic("/waku/2/default-content/proto")
      pubsubTopic =  "/waku/2/default-waku/proto"

      t1 = epochTime()
      t2 = epochTime()
      t3 = high(float64)
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

    var responseCount = 0
    proc data(receiverTimestamp: float64, msg: WakuMessage, psTopic: string) =
      responseCount += 1
      check msg in msgs
      check psTopic == pubsubTopic

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
      if receiverTimestamp == indexes[0].receivedTime: rt1Flag = true
      if receiverTimestamp == indexes[1].receivedTime: rt2Flag = true
      if receiverTimestamp == indexes[2].receivedTime: rt3Flag = true


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
  test "reads user_version":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      store = WakuMessageStore.init(database)[]
    defer: store.close()

    var gotMessages: bool
    proc migrate(s: ptr sqlite3_stmt) = 
      gotMessages = true
      let version = sqlite3_column_int64(s, 0)
      debug "the current user version", version=version

    let res = database.query("PRAGMA user_version;", migrate)
    check:
      res.isErr == false
      gotMessages == true
  test "migrate":
    migrate(2, "/Users/sanaztaheri/GitHub/nim-waku-code/nim-waku/waku/v2/node/storage/message/migrations")
    check true
  # test "updates user_version":
  #   # initialize the db
  #   let 
  #     database = SqliteDatabase.init("", inMemory = true)[]
  #     store = WakuMessageStore.init(database)[]
  #   defer: store.close()

  #   # # update user version
  #   # let prepare = database.prepareStmt("PRAGMA user_version= (?);", (int64), void)
  #   # check:
  #   #   prepare.isErr == false

  #   # let updateRes = prepare.value.exec((int64(40)))
  #   # check:
  #   #   updateRes.isErr == false
  #   checkExec "PRAGMA user_version = 40;"

  #   # check the version
  #   var gotMessages: bool
  #   proc migrate(s: ptr sqlite3_stmt) = 
  #     gotMessages = true
  #     let version = sqlite3_column_int64(s, 0)
  #     debug "the current user version", version=version
  #     check:
  #       version == 40.int64

  #   let res = database.query("PRAGMA user_version;", migrate)
  #   check:
  #     res.isErr == false
  #     gotMessages == true

