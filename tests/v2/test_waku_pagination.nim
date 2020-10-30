{.used.}
import
  std/[unittest,algorithm],
  nimcrypto/sha2,
  stew/byteutils,
  ../../waku/node/v2/waku_types,
  ../../waku/protocol/v2/waku_store,
  ../test_helpers


proc CreateSampleList( size : int) : seq[IndexedWakuMessage] =
  let data: array[32, byte] = [byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
  for i in 0..<size:
    result.add(IndexedWakuMessage(msg: WakuMessage(payload: @[byte i]), index: Index(receivedTime: float64(i), digest: MDigest[256](data: data)) ))

procSuite "pagination":
  test "computeindex: empty contentTopic test":
    let
      wm = WakuMessage(payload: @[byte 1, 2, 3])
      index = wm.computeIndex()
    check:
      # the fields of the index should be non-empty
      len(index.digest.data) != 0
      len(index.digest.data) == 32 # sha2 output length in bytes
      index.receivedTime != 0 # the timestamp should be a non-zero value

  test "computeindex: identical WakuMessages test":
    let
      wm = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic(1))
      index1 = wm.computeIndex()
      wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic(1))
      index2 = wm2.computeIndex()

    check:
      # the digests of two identical WakuMessages must be the same
      index1.digest == index2.digest
  test "Index comparison and indexedWakuMessage comparison and sort test":
    let
      data1: array[32, byte] = [byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
          1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
      data2: array[32, byte] = [byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
          1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]
      data3: array[32, byte] = [byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
          1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3]
      

      index1: Index = Index(receivedTime: 1, digest: MDigest[256](data: data1))
      index2: Index = Index(receivedTime: 1, digest: MDigest[256](data: data2))
      index3: Index = Index(receivedTime: 2, digest: MDigest[256](data: data3))
      

      iwm1 = IndexedWakuMessage(index: index1)
      iwm2 = IndexedWakuMessage(index: index2)
      iwm3 = IndexedWakuMessage(index: index3)

    check:
      indexComparison(index1, index1) == 0
      indexComparison(index1, index2) == -1
      indexComparison(index2, index1) == 1
      indexComparison(index1, index3) == -1
      indexComparison(index3, index1) == 1

    check:
      indexedWakuMessageComparison(iwm1, iwm1) == 0
      indexedWakuMessageComparison(iwm1, iwm2) == -1
      indexedWakuMessageComparison(iwm2, iwm1) == 1
      indexedWakuMessageComparison(iwm1, iwm3) == -1
      indexedWakuMessageComparison(iwm3, iwm1) == 1
    
    var sortingList= @[iwm3,iwm1,iwm2 ]
    sortingList.sort(indexedWakuMessageComparison)
    check: 
      sortingList[0] ==  iwm1
      sortingList[1] ==  iwm2
      sortingList[2] ==  iwm3
      
  
  test "Find index test": 
    let
      msgList = CreateSampleList(10)
    check:
      msgList.findIndex( msgList[3].index) == 3
      msgList.findIndex(Index()) == -1 

  test "Forward pagination test":
    let msgList = CreateSampleList(10)

    var pagingInfo = PagingInfo(pageSize: 2, cursor: msgList[3].index, direction: PagingDirection.FORWARD)
    # test for a normal pagination
    var (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 2
      data == msgList[4..5]
      newPagingInfo.cursor == msgList[5].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == pagingInfo.pageSize
   
   # test for an intial pagination request with empty cursor
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 2
      data == msgList[0..1]
      newPagingInfo.cursor == msgList[1].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 2

  
    # test for a page size larger than the remaining messages
    pagingInfo = PagingInfo(pageSize: 10, cursor: msgList[3].index, direction: PagingDirection.FORWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 6
      data == msgList[4..9]
      newPagingInfo.cursor == msgList[9].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 6
  
    

    # test for a page size larger than the maximum allowed page size
    pagingInfo = PagingInfo(pageSize: MaxPageSize+1, cursor: msgList[3].index, direction: PagingDirection.FORWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len <= MaxPageSize
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize <= MaxPageSize
  
    
    # test for a cursor poiting to the end of the message list
    pagingInfo = PagingInfo(pageSize: 10, cursor: msgList[9].index, direction: PagingDirection.FORWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == msgList[9].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
    
    # test for an invalid cursor 
    pagingInfo = PagingInfo(pageSize: 10, cursor: computeIndex(WakuMessage(payload: @[byte 10])), direction: PagingDirection.FORWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == pagingInfo.cursor
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
 
  test "Backward pagination test":
    var
      msgList = CreateSampleList(10)

      pagingInfo = PagingInfo(pageSize: 2, cursor: msgList[3].index, direction: PagingDirection.BACKWARD)

    # test for a normal pagination
    var (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data == msgList[1..2]
      newPagingInfo.cursor == msgList[1].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == pagingInfo.pageSize
    
    # test for an intial pagination request with empty cursor
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 2
      data == msgList[8..9]
      newPagingInfo.cursor == msgList[8].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 2


    # test for a page size larger than the remaining messages
    pagingInfo = PagingInfo(pageSize: 5, cursor: msgList[3].index, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data == msgList[0..2]
      newPagingInfo.cursor == msgList[0].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 3
    
    # test for a page size larger than the Maximum allowed page size
    pagingInfo = PagingInfo(pageSize: MaxPageSize+1, cursor: msgList[3].index, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len <= MaxPageSize
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize <= MaxPageSize

    # test for a cursor poiting to the end of the message list
    pagingInfo = PagingInfo(pageSize: 5, cursor: msgList[0].index, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == msgList[0].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0

    # test for an invalid cursor 
    pagingInfo = PagingInfo(pageSize: 5, cursor: computeIndex(WakuMessage(payload: @[byte 10])), direction: PagingDirection.BACKWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 0
      newPagingInfo.cursor == pagingInfo.cursor
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 0
 

    
