{.used.}

import
  std/[sequtils, algorithm],
  stew/results,
  testutils/unittests
import
  ../../waku/v2/node/storage/message/waku_store_queue,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/utils/time


# Helper functions

proc genIndexedWakuMessage(i: int8): IndexedWakuMessage =
  ## Use i to generate an IndexedWakuMessage
  var data {.noinit.}: array[32, byte]
  for x in data.mitems: x = i.byte
  
  let
    message = WakuMessage(payload: @[byte i], timestamp: Timestamp(i))
    cursor = Index(
      receiverTime: Timestamp(i), 
      senderTime: Timestamp(i), 
      digest: MessageDigest(data: data),
      pubsubTopic: "test-pubsub-topic"
    )

  IndexedWakuMessage(msg: message, index: cursor)

proc getPrepopulatedTestStore(unsortedSet: auto, capacity: int): StoreQueueRef =
  let store = StoreQueueRef.new(capacity)
  
  for i in unsortedSet:
    let message = genIndexedWakuMessage(i.int8)
    discard store.add(message)

  store
  

procSuite "Sorted store queue":

  test "Store capacity - add a message over the limit":
    ## Given
    let capacity = 5
    let store = StoreQueueRef.new(capacity)
    
    ## When
    # Fill up the queue
    for i in 1..capacity: 
      let message = genIndexedWakuMessage(i.int8)
      require(store.add(message).isOk())

    # Add one more. Capacity should not be exceeded
    let message = genIndexedWakuMessage(capacity.int8 + 1)
    require(store.add(message).isOk())
    
    ## Then
    check:
      store.len == capacity
     
  test "Store capacity - add message older than oldest in the queue":
    ## Given
    let capacity = 5
    let store = StoreQueueRef.new(capacity)
    
    ## When
    # Fill up the queue
    for i in 1..capacity: 
      let message = genIndexedWakuMessage(i.int8)
      require(store.add(message).isOk())
    
    # Attempt to add message with older value than oldest in queue should fail
    let
      oldestTimestamp = store.first().get().index.senderTime
      message = genIndexedWakuMessage(oldestTimestamp.int8 - 1)
      addRes = store.add(message)
    
    ## Then
    check:
      addRes.isErr()
      addRes.error() == "too_old"

    check:
      store.len == capacity

  test "Store queue sort-on-insert works":    
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)

    # Walk forward through the set and verify ascending order
    var prevSmaller = genIndexedWakuMessage(min(unsortedSet).int8 - 1).index
    for i in store.fwdIterator:
      let (index, indexedWakuMessage) = i
      check cmp(index, prevSmaller) > 0
      prevSmaller = index
    
    # Walk backward through the set and verify descending order
    var prevLarger = genIndexedWakuMessage(max(unsortedSet).int8 + 1).index
    for i in store.bwdIterator:
      let (index, indexedWakuMessage) = i
      check cmp(index, prevLarger) < 0
      prevLarger = index
  
  test "access first item from store queue":
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)

    ## When
    let firstRes = store.first()
    
    ## Then
    check:
      firstRes.isOk()
    
    let first = firstRes.tryGet()
    check:
      first.msg.timestamp == Timestamp(1)

  test "get first item from empty store should fail":
    ## Given
    let capacity = 5
    let store = StoreQueueRef.new(capacity)
    
    ## When
    let firstRes = store.first()

    ## Then
    check:
      firstRes.isErr()
      firstRes.error() == "Not found"

  test "access last item from store queue":
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)

    ## When
    let lastRes = store.last()
    
    ## Then
    check:
      lastRes.isOk()
    
    let last = lastRes.tryGet()
    check:
      last.msg.timestamp == Timestamp(5)

  test "get last item from empty store should fail":
    ## Given 
    let capacity = 5
    let store = StoreQueueRef.new(capacity)
    
    ## When
    let lastRes = store.last()

    ## Then
    check:
      lastRes.isErr()
      lastRes.error() == "Not found"

  test "Store queue pagination works with predicate - fwd direction":
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)

    proc onlyEvenTimes(i: IndexedWakuMessage): bool = i.msg.timestamp.int64 mod 2 == 0

    ## When
    let pageRes1 = store.getPage(onlyEvenTimes, PagingInfo(pageSize: 2, direction: PagingDirection.FORWARD))
    
    ## Then
    # First page
    check pageRes1.isOk()

    var res = pageRes1.get().mapIt(it[1])
    check:
      res.mapIt(it.timestamp.int) == @[2,4]
    

  test "Store queue pagination works with predicate - bwd direction":
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)

    proc onlyOddTimes(i: IndexedWakuMessage): bool = i.msg.timestamp.int64 mod 2 != 0

    ## When
    let pageRes1 = store.getPage(onlyOddTimes, PagingInfo(pageSize: 2, direction: PagingDirection.BACKWARD))
    
    ## Then
    # First page
    check pageRes1.isOk()

    var res = pageRes1.get().mapIt(it[1])
    check:
      res.mapIt(it.timestamp.int) == @[3,5].reversed
    
  test "handle pagination on empty store - fwd direction":
    ## Given
    let capacity = 5
    let store = StoreQueueRef.new(capacity)
    
    proc predicate(i: IndexedWakuMessage): bool = true # no filtering

    let pagingInfo = PagingInfo(pageSize: 3, direction: PagingDirection.FORWARD)

    ## When
    # Get page from empty queue in fwd dir
    let pageRes = store.getPage(predicate, pagingInfo)

    ## Then
    # Empty response
    check pageRes.isOk()

    var res = pageRes.get()
    check:
      res.len == 0

  test "handle pagination on empty store - bwd direction":
    ## Given 
    let capacity = 5
    let store = StoreQueueRef.new(capacity)
    
    proc predicate(i: IndexedWakuMessage): bool = true # no filtering
    
    let pagingInfo = PagingInfo(pageSize: 3, direction: PagingDirection.BACKWARD)

    ## When
    # Get page from empty queue in bwd dir
    let pageRes = store.getPage(predicate, pagingInfo)

    ## Then
    # Empty response
    check pageRes.isOk()

    let res = pageRes.get()
    check:
      res.len == 0
    
  test "handle invalid cursor - fwd direction":   
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)

    proc predicate(i: IndexedWakuMessage): bool = true # no filtering

    let cursor = PagingIndex(receiverTime: Timestamp(3), senderTime: Timestamp(3), digest: MessageDigest())
    let pagingInfo = PagingInfo(pageSize: 3, cursor: cursor, direction: PagingDirection.FORWARD)

    ## When
    let pageRes = store.getPage(predicate, pagingInfo)

    ## Then
    check:
      pageRes.isErr()
      pageRes.error == HistoryResponseError.INVALID_CURSOR

  test "handle invalid cursor - bwd direction":   
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)

    proc predicate(i: IndexedWakuMessage): bool = true # no filtering

    let cursor = PagingIndex(receiverTime: Timestamp(3), senderTime: Timestamp(3), digest: MessageDigest())
    let pagingInfo = PagingInfo(pageSize: 3, cursor: cursor, direction: PagingDirection.BACKWARD)

    ## When
    let pageRes = store.getPage(predicate, pagingInfo)

    ## Then
    # Empty response with error
    check:
      pageRes.isErr()
      pageRes.error == HistoryResponseError.INVALID_CURSOR

  test "verify if store queue contains an index":
    ## Given
    let
      capacity = 5
      unsortedSet = [5,1,3,2,4]
    let store = getPrepopulatedTestStore(unsortedSet, capacity)
    
    let
      existingIndex = genIndexedWakuMessage(4).index
      nonExistingIndex = genIndexedWakuMessage(99).index
    
    ## Then
    check:
      store.contains(existingIndex) == true
      store.contains(nonExistingIndex) == false
