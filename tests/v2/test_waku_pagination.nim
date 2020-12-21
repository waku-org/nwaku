{.used.}
import
  std/[unittest,algorithm,options],
  nimcrypto/sha2,
  ../../waku/v2/waku_types,
  ../../waku/v2/protocol/waku_store/waku_store,
  ../test_helpers


proc createSampleList(s: int): seq[IndexedWakuMessage] =
  ## takes s as input and outputs a sequence with s amount of IndexedWakuMessage 
  var data {.noinit.}: array[32, byte]
  for x in data.mitems: x = 1
  for i in 0..<s:
    result.add(IndexedWakuMessage(msg: WakuMessage(payload: @[byte i]), index: Index(receivedTime: float64(i), digest: MDigest[256](data: data)) ))

procSuite "pagination":
  test "Index computation test":
    let
      wm = WakuMessage(payload: @[byte 1, 2, 3])
      index = wm.computeIndex()
    check:
      # the fields of the index should be non-empty
      len(index.digest.data) != 0
      len(index.digest.data) == 32 # sha2 output length in bytes
      index.receivedTime != 0 # the timestamp should be a non-zero value

    let
      wm1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic(1))
      index1 = wm1.computeIndex()
      wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: ContentTopic(1))
      index2 = wm2.computeIndex()

    check:
      # the digests of two identical WakuMessages must be the same
      index1.digest == index2.digest

  test "Index comparison, IndexedWakuMessage comparison, and Sorting tests":
    var data1 {.noinit.}: array[32, byte]
    for x in data1.mitems: x = 1
    var data2 {.noinit.}: array[32, byte]
    for x in data2.mitems: x = 2
    var data3 {.noinit.}: array[32, byte]
    for x in data3.mitems: x = 3
      
    let
      index1 = Index(receivedTime: 1, digest: MDigest[256](data: data1))
      index2 = Index(receivedTime: 1, digest: MDigest[256](data: data2))
      index3 = Index(receivedTime: 2, digest: MDigest[256](data: data3))
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
    
    var sortingList = @[iwm3, iwm1, iwm2]
    sortingList.sort(indexedWakuMessageComparison)
    check: 
      sortingList[0] == iwm1
      sortingList[1] == iwm2
      sortingList[2] == iwm3
      
  
  test "Find Index test": 
    let msgList = createSampleList(10)
    check:
      msgList.findIndex(msgList[3].index).get() == 3
      msgList.findIndex(Index()).isNone == true

  test "Forward pagination test":
    var 
      msgList = createSampleList(10)
      pagingInfo = PagingInfo(pageSize: 2, cursor: msgList[3].index, direction: PagingDirection.FORWARD)

    # test for a normal pagination
    var (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 2
      data == msgList[4..5]
      newPagingInfo.cursor == msgList[5].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == pagingInfo.pageSize
   
   # test for an initial pagination request with an empty cursor
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD)
    (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data.len == 2
      data == msgList[0..1]
      newPagingInfo.cursor == msgList[1].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == 2

    # test for an empty msgList
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD)
    (data, newPagingInfo) = paginateWithIndex(@[], pagingInfo)
    check:
      data.len == 0
      newPagingInfo.pageSize == 0
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.cursor == pagingInfo.cursor

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
      msgList = createSampleList(10)
      pagingInfo = PagingInfo(pageSize: 2, cursor: msgList[3].index, direction: PagingDirection.BACKWARD)

    # test for a normal pagination
    var (data, newPagingInfo) = paginateWithIndex(msgList, pagingInfo)
    check:
      data == msgList[1..2]
      newPagingInfo.cursor == msgList[1].index
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.pageSize == pagingInfo.pageSize

    # test for an empty msgList
    pagingInfo = PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD)
    (data, newPagingInfo) = paginateWithIndex(@[], pagingInfo)
    check:
      data.len == 0
      newPagingInfo.pageSize == 0
      newPagingInfo.direction == pagingInfo.direction
      newPagingInfo.cursor == pagingInfo.cursor

    # test for an initial pagination request with an empty cursor
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

    # test for a cursor pointing to the begining of the message list
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
