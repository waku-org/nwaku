{.used.}

import
  std/[options, sequtils, times],
  testutils/unittests, 
  nimcrypto/sha2,
  libp2p/protobuf/minprotobuf
import
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/utils/time,
  ../../waku/v2/utils/pagination


const 
  DefaultPubsubTopic = "/waku/2/default-waku/proto"
  DefaultContentTopic = ContentTopic("/waku/2/default-content/proto")


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

proc getTestTimestamp(): Timestamp =
  let now = getNanosecondTime(epochTime())
  Timestamp(now)

suite "Queue store - pagination":
  test "Forward pagination test":
    var
      stQ = getTestStoreQueue(10)
      indexList = toSeq(stQ.fwdIterator()).mapIt(it[0]) # Seq copy of the store queue indices for verification
      msgList = toSeq(stQ.fwdIterator()).mapIt(it[1].msg) # Seq copy of the store queue messages for verification
      pagingInfo = PagingInfo(pageSize: 2, cursor: indexList[3], direction: PagingDirection.FORWARD)

    # test for a normal pagination
    var (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 2
      data == msgList[4..5]
      newPagingInfo.cursor == indexList[5]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == pagingInfo.pageSize
      error == HistoryResponseError.NONE
   
   # test for an initial pagination request with an empty cursor
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 2
      data == msgList[0..1]
      newPagingInfo.cursor == indexList[1]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 2
      error == HistoryResponseError.NONE
    
    # test for an initial pagination request with an empty cursor to fetch the entire history
    pagingInfo = PagingInfo(pageSize: 13, direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 10
      data == msgList[0..9]
      newPagingInfo.cursor == indexList[9]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 10
      error == HistoryResponseError.NONE

    # test for an empty msgList
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(getTestStoreQueue(0), pagingInfo)
    check:
      data.len == 0
      newPagingInfo.pageSize == 0
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.cursor == pagingInfo.cursor
      error == HistoryResponseError.NONE

    # test for a page size larger than the remaining messages
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[3], direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 6
      data == msgList[4..9]
      newPagingInfo.cursor == indexList[9]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 6
      error == HistoryResponseError.NONE

    # test for a page size larger than the maximum allowed page size
    pagingInfo = PagingInfo(pageSize: MaxPageSize+1, cursor: indexList[3], direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      uint64(data.len) <= MaxPageSize
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize <= MaxPageSize
      error == HistoryResponseError.NONE
  
    # test for a cursor pointing to the end of the message list
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[9], direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == indexList[9]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.NONE
    
    # test for an invalid cursor 
    let index = Index.compute(WakuMessage(payload: @[byte 10]), getTestTimestamp(), DefaultPubsubTopic)
    pagingInfo = PagingInfo(pageSize: 10, cursor: index, direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == pagingInfo.cursor
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.INVALID_CURSOR

    # test initial paging query over a message list with one message 
    var singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(singleItemMsgList, pagingInfo)
    check:
      data.len == 1
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 1
      error == HistoryResponseError.NONE

    # test pagination over a message list with one message
    singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[0], direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(singleItemMsgList, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.NONE

  test "Backward pagination test":
    var
      stQ = getTestStoreQueue(10)
      indexList = toSeq(stQ.fwdIterator()).mapIt(it[0]) # Seq copy of the store queue indices for verification
      msgList = toSeq(stQ.fwdIterator()).mapIt(it[1].msg) # Seq copy of the store queue messages for verification
      pagingInfo = PagingInfo(pageSize: 2, cursor: indexList[3], direction: PagingDirection.BACKWARD)

    # test for a normal pagination
    var (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data == msgList[1..2]
      newPagingInfo.cursor == indexList[1]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == pagingInfo.pageSize
      error == HistoryResponseError.NONE

    # test for an empty msgList
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(getTestStoreQueue(0), pagingInfo)
    check:
      data.len == 0
      newPagingInfo.pageSize == 0
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.cursor == pagingInfo.cursor
      error == HistoryResponseError.NONE

    # test for an initial pagination request with an empty cursor
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 2
      data == msgList[8..9]
      newPagingInfo.cursor == indexList[8]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 2
      error == HistoryResponseError.NONE
    
    # test for an initial pagination request with an empty cursor to fetch the entire history
    pagingInfo = PagingInfo(pageSize: 13, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 10
      data == msgList[0..9]
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 10
      error == HistoryResponseError.NONE

    # test for a page size larger than the remaining messages
    pagingInfo = PagingInfo(pageSize: 5, cursor: indexList[3], direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data == msgList[0..2]
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 3
      error == HistoryResponseError.NONE
    
    # test for a page size larger than the Maximum allowed page size
    pagingInfo = PagingInfo(pageSize: MaxPageSize+1, cursor: indexList[3], direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      uint64(data.len) <= MaxPageSize
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize <= MaxPageSize
      error == HistoryResponseError.NONE

    # test for a cursor pointing to the begining of the message list
    pagingInfo = PagingInfo(pageSize: 5, cursor: indexList[0], direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)

    check:
      data.len == 0
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.NONE

    # test for an invalid cursor 
    let index = Index.compute(WakuMessage(payload: @[byte 10]), getTestTimestamp(), DefaultPubsubTopic)
    pagingInfo = PagingInfo(pageSize: 5, cursor: index, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == pagingInfo.cursor
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.INVALID_CURSOR
    
    # test initial paging query over a message list with one message
    var singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(singleItemMsgList, pagingInfo)
    check:
      data.len == 1
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 1
      error == HistoryResponseError.NONE
    
    # test paging query over a message list with one message
    singleItemMsgList = getTestStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[0], direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(singleItemMsgList, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.NONE
