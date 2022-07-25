{.used.}

import
  std/[options, sequtils],
  testutils/unittests, 
  nimcrypto/sha2,
  libp2p/protobuf/minprotobuf
import
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/utils/time,
  ../../waku/v2/utils/pagination


proc createSampleStoreQueue(s: int): StoreQueueRef =
  ## takes s as input and outputs a StoreQueue with s amount of IndexedWakuMessage 
  
  let testStoreQueue = StoreQueueRef.new(s)
  
  var data {.noinit.}: array[32, byte]
  for x in data.mitems: x = 1

  for i in 0..<s:
    discard testStoreQueue.add(IndexedWakuMessage(msg: WakuMessage(payload: @[byte i]),
                                                  index: Index(receiverTime: Timestamp(i),
                                                               senderTime: Timestamp(i),
                                                               digest: MDigest[256](data: data)) ))
  
  return testStoreQueue

procSuite "pagination":
  test "Index computation test":
    let
      wm = WakuMessage(payload: @[byte 1, 2, 3], timestamp: 2)
      index = wm.computeIndex()
    check:
      # the fields of the index should be non-empty
      len(index.digest.data) != 0
      len(index.digest.data) == 32 # sha2 output length in bytes
      index.receiverTime != 0 # the receiver timestamp should be a non-zero value
      index.senderTime == 2
      index.pubsubTopic == DefaultTopic

    let
      wm1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic("/waku/2/default-content/proto"))
      index1 = wm1.computeIndex()
      wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic("/waku/2/default-content/proto"))
      index2 = wm2.computeIndex()

    check:
      # the digests of two identical WakuMessages must be the same
      index1.digest == index2.digest

  test "Forward pagination test":
    var
      stQ = createSampleStoreQueue(10)
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
    (data, newPagingInfo, error) = getPage(createSampleStoreQueue(0), pagingInfo)
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
    pagingInfo = PagingInfo(pageSize: 10, cursor: computeIndex(WakuMessage(payload: @[byte 10])), direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == pagingInfo.cursor
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.INVALID_CURSOR

    # test initial paging query over a message list with one message 
    var singleItemMsgList = createSampleStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, direction: PagingDirection.FORWARD)
    (data, newPagingInfo, error) = getPage(singleItemMsgList, pagingInfo)
    check:
      data.len == 1
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 1
      error == HistoryResponseError.NONE

    # test pagination over a message list with one message
    singleItemMsgList = createSampleStoreQueue(1)
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
      stQ = createSampleStoreQueue(10)
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
    (data, newPagingInfo, error) = getPage(createSampleStoreQueue(0), pagingInfo)
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
    pagingInfo = PagingInfo(pageSize: 5, cursor: computeIndex(WakuMessage(payload: @[byte 10])), direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(stQ, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == pagingInfo.cursor
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.INVALID_CURSOR
    
    # test initial paging query over a message list with one message
    var singleItemMsgList = createSampleStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(singleItemMsgList, pagingInfo)
    check:
      data.len == 1
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 1
      error == HistoryResponseError.NONE
    
    # test paging query over a message list with one message
    singleItemMsgList = createSampleStoreQueue(1)
    pagingInfo = PagingInfo(pageSize: 10, cursor: indexList[0], direction: PagingDirection.BACKWARD)
    (data, newPagingInfo, error) = getPage(singleItemMsgList, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == indexList[0]
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
      error == HistoryResponseError.NONE

suite "time-window history query":
  test "Encode/Decode waku message with timestamp":
    # test encoding and decoding of the timestamp field of a WakuMessage 
    # Encoding
    let
      version = 0'u32
      payload = @[byte 0, 1, 2]
      timestamp = Timestamp(10)
      msg = WakuMessage(payload: payload, version: version, timestamp: timestamp)
      pb =  msg.encode()
    
    # Decoding
    let
      msgDecoded = WakuMessage.init(pb.buffer)
    check:
      msgDecoded.isOk()
    
    let 
      timestampDecoded = msgDecoded.value.timestamp
    check:
      timestampDecoded == timestamp

  test "Encode/Decode waku message without timestamp":
    # test the encoding and decoding of a WakuMessage with an empty timestamp field  

    # Encoding
    let
      version = 0'u32
      payload = @[byte 0, 1, 2]
      msg = WakuMessage(payload: payload, version: version)
      pb =  msg.encode()
      
    # Decoding
    let
      msgDecoded = WakuMessage.init(pb.buffer)
    doAssert:
      msgDecoded.isOk()
    
    let 
      timestampDecoded = msgDecoded.value.timestamp
    check:
      timestampDecoded == Timestamp(0)
