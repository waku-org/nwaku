{.used.}

import
  std/[sequtils, algorithm],
  testutils/unittests, 
  nimcrypto/sha2,
  libp2p/protobuf/minprotobuf
import
  ../../waku/v2/node/message_store/waku_store_queue,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/utils/time,
  ./testlib/common


proc getTestStoreQueue(numMessages: int): StoreQueueRef =
  let testStoreQueue = StoreQueueRef.new(numMessages)
  
  var data {.noinit.}: array[32, byte]
  for x in data.mitems: x = 1

  for i in 0..<numMessages:
    let msg = IndexedWakuMessage(
      msg: WakuMessage(payload: @[byte i]),
      index: Index(
        receiverTime: Timestamp(i),
        senderTime: Timestamp(i),
        digest: MDigest[256](data: data)
      ) 
    )
    discard testStoreQueue.add(msg)
  
  return testStoreQueue


suite "Queue store - pagination":
  test "Forward pagination test":
    let
      store = getTestStoreQueue(10)
      indexList = toSeq(store.fwdIterator()).mapIt(it[0]) # Seq copy of the store queue indices for verification
      msgList = toSeq(store.fwdIterator()).mapIt(it[1].msg) # Seq copy of the store queue messages for verification
      
    var pagingInfo = PagingInfo(pageSize: 2, cursor: indexList[3].toPagingIndex(), direction: PagingDirection.FORWARD)

    # test for a normal pagination
    var data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 2
      data == msgList[4..5]
   
   # test for an initial pagination request with an empty cursor
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 2
      data == msgList[0..1]
    
    # test for an initial pagination request with an empty cursor to fetch the entire history
    pagingInfo = PagingInfo(pageSize: 13, direction: PagingDirection.FORWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 10
      data == msgList[0..9]

    # test for an empty msgList
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD)
    data = getPage(getTestStoreQueue(0), pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 0

    # test for a page size larger than the remaining messages
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[3].toPagingIndex(), direction: PagingDirection.FORWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 6
      data == msgList[4..9]

    # test for a page size larger than the maximum allowed page size
    pagingInfo = PagingInfo(pageSize: MaxPageSize+1, cursor: indexList[3].toPagingIndex(), direction: PagingDirection.FORWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      uint64(data.len) <= MaxPageSize
  
    # test for a cursor pointing to the end of the message list
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[9].toPagingIndex(), direction: PagingDirection.FORWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 0
    
    # test for an invalid cursor 
    let index = PagingIndex.compute(WakuMessage(payload: @[byte 10]), ts(), DefaultPubsubTopic)
    pagingInfo = PagingInfo(pageSize: 10, cursor: index, direction: PagingDirection.FORWARD)
    var error = getPage(store, pagingInfo).tryError()
    check:
      error == HistoryResponseError.INVALID_CURSOR

    # test initial paging query over a message list with one message 
    var singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, direction: PagingDirection.FORWARD)
    data = getPage(singleItemMsgList, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 1

    # test pagination over a message list with one message
    singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[0].toPagingIndex(), direction: PagingDirection.FORWARD)
    data = getPage(singleItemMsgList, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 0

  test "Backward pagination test":
    let
      store = getTestStoreQueue(10)
      indexList = toSeq(store.fwdIterator()).mapIt(it[0]) # Seq copy of the store queue indices for verification
      msgList = toSeq(store.fwdIterator()).mapIt(it[1].msg) # Seq copy of the store queue messages for verification
    
    var pagingInfo = PagingInfo(pageSize: 2, cursor: indexList[3].toPagingIndex(), direction: PagingDirection.BACKWARD)

    # test for a normal pagination
    var data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data == msgList[1..2].reversed

    # test for an empty msgList
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD)
    data = getPage(getTestStoreQueue(0), pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 0

    # test for an initial pagination request with an empty cursor
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 2
      data == msgList[8..9].reversed
    
    # test for an initial pagination request with an empty cursor to fetch the entire history
    pagingInfo = PagingInfo(pageSize: 13, direction: PagingDirection.BACKWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 10
      data == msgList[0..9].reversed

    # test for a page size larger than the remaining messages
    pagingInfo = PagingInfo(pageSize: 5, cursor: indexList[3].toPagingIndex(), direction: PagingDirection.BACKWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data == msgList[0..2].reversed
    
    # test for a page size larger than the Maximum allowed page size
    pagingInfo = PagingInfo(pageSize: MaxPageSize+1, cursor: indexList[3].toPagingIndex(), direction: PagingDirection.BACKWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      uint64(data.len) <= MaxPageSize

    # test for a cursor pointing to the begining of the message list
    pagingInfo = PagingInfo(pageSize: 5, cursor: indexList[0].toPagingIndex(), direction: PagingDirection.BACKWARD)
    data = getPage(store, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 0

    # test for an invalid cursor 
    let index = PagingIndex.compute(WakuMessage(payload: @[byte 10]), ts(), DefaultPubsubTopic)
    pagingInfo = PagingInfo(pageSize: 5, cursor: index, direction: PagingDirection.BACKWARD)
    var error = getPage(store, pagingInfo).tryError()
    check:
      error == HistoryResponseError.INVALID_CURSOR
    
    # test initial paging query over a message list with one message
    var singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, direction: PagingDirection.BACKWARD)
    data = getPage(singleItemMsgList, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 1
    
    # test paging query over a message list with one message
    singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[0].toPagingIndex(), direction: PagingDirection.BACKWARD)
    data = getPage(singleItemMsgList, pagingInfo).tryGet().mapIt(it[1])
    check:
      data.len == 0
