{.push raises: [Defect].}

import
  std/[options, algorithm],
  stew/[results, sorted_set],
  chronicles
import
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/rpc,
  ../../../utils/pagination,
  ../../../utils/time,
  ./message_store

export pagination

logScope:
  topics = "message_store.storequeue"


const StoreQueueDefaultMaxCapacity* = 25_000


type 
  IndexedWakuMessage* = object
    # TODO may need to rename this object as it holds both the index and the pubsub topic of a waku message
    ## This type is used to encapsulate a WakuMessage and its Index
    msg*: WakuMessage
    index*: Index
    pubsubTopic*: string
    
  QueryFilterMatcher* = proc(indexedWakuMsg: IndexedWakuMessage) : bool {.gcsafe, closure.}


type
  StoreQueueRef* = ref object of MessageStore
    ## Bounded repository for indexed messages
    ## 
    ## The store queue will keep messages up to its
    ## configured capacity. As soon as this capacity
    ## is reached and a new message is added, the oldest
    ## item will be removed to make space for the new one.
    ## This implies both a `delete` and `add` operation
    ## for new items.
    ## 
    ## @ TODO: a circular/ring buffer may be a more efficient implementation
    ## @ TODO: we don't need to store the Index twice (as key and in the value)
    items: SortedSet[Index, IndexedWakuMessage] # sorted set of stored messages
    capacity: int # Maximum amount of messages to keep


### Helpers 

proc ffdToCursor(w: SortedSetWalkRef[Index, IndexedWakuMessage],
                 startCursor: Index):
                 SortedSetResult[Index, IndexedWakuMessage] =
  ## Fast forward `w` to start cursor
  ## TODO: can probably improve performance here with a binary/tree search
  
  var nextItem = w.first

  trace "Fast forwarding to start cursor", startCursor=startCursor, firstItem=nextItem
  
  ## Fast forward until we reach the startCursor
  while nextItem.isOk:
    if nextItem.value.key == startCursor:
      # Exit ffd loop when we find the start cursor
      break

    # Not yet at cursor. Continue advancing
    nextItem = w.next
    trace "Continuing ffd to start cursor", nextItem=nextItem

  return nextItem

proc rwdToCursor(w: SortedSetWalkRef[Index, IndexedWakuMessage],
                 startCursor: Index):
                 SortedSetResult[Index, IndexedWakuMessage] =
  ## Rewind `w` to start cursor
  ## TODO: can probably improve performance here with a binary/tree search
  
  var prevItem = w.last

  trace "Rewinding to start cursor", startCursor=startCursor, lastItem=prevItem

  ## Rewind until we reach the startCursor
  
  while prevItem.isOk:
    if prevItem.value.key == startCursor:
      # Exit rwd loop when we find the start cursor
      break

    # Not yet at cursor. Continue rewinding.
    prevItem = w.prev
    trace "Continuing rewind to start cursor", prevItem=prevItem
  
  return prevItem

proc fwdPage(storeQueue: StoreQueueRef,
             pred: QueryFilterMatcher,
             maxPageSize: uint64,
             startCursor: Option[Index]):
            (seq[WakuMessage], PagingInfo, HistoryResponseError) =
  ## Populate a single page in forward direction
  ## Start at the `startCursor` (exclusive), or first entry (inclusive) if not defined.
  ## Page size must not exceed `maxPageSize`
  ## Each entry must match the `pred`
  
  trace "Retrieving fwd page from store queue", len=storeQueue.items.len, maxPageSize=maxPageSize, startCursor=startCursor
  
  var
    outSeq: seq[WakuMessage]
    outPagingInfo: PagingInfo
    outError: HistoryResponseError
  
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    currentEntry: SortedSetResult[Index, IndexedWakuMessage]
    lastValidCursor: Index
  
  # Find first entry
  if startCursor.isSome():
    lastValidCursor = startCursor.get()

    let cursorEntry = w.ffdToCursor(startCursor.get())
    if cursorEntry.isErr:
      # Quick exit here if start cursor not found
      trace "Could not find starting cursor. Returning empty result.", startCursor=startCursor
      outSeq = @[]
      outPagingInfo = PagingInfo(pageSize: 0, cursor: startCursor.get(), direction: PagingDirection.FORWARD)
      outError = HistoryResponseError.INVALID_CURSOR
      w.destroy
      return (outSeq, outPagingInfo, outError)
    
    # Advance walker once more
    currentEntry = w.next
  else:
    # Start from the beginning of the queue
    lastValidCursor = Index() # No valid (only empty) last cursor
    currentEntry = w.first

  trace "Starting fwd page query", currentEntry=currentEntry

  ## This loop walks forward over the queue:
  ## 1. from the given cursor (or first entry, if not provided)
  ## 2. adds entries matching the predicate function to output page
  ## 3. until either the end of the queue or maxPageSize is reached
  var numberOfItems = 0.uint
  while currentEntry.isOk and numberOfItems < maxPageSize:

    trace "Continuing fwd page query", currentEntry=currentEntry, numberOfItems=numberOfItems
    
    if pred(currentEntry.value.data):
      trace "Current item matches predicate. Adding to output."
      lastValidCursor = currentEntry.value.key
      outSeq.add(currentEntry.value.data.msg)
      numberOfItems += 1
    currentEntry = w.next
  w.destroy

  outPagingInfo = PagingInfo(pageSize: outSeq.len.uint,
                             cursor: lastValidCursor,
                             direction: PagingDirection.FORWARD)

  outError = HistoryResponseError.NONE

  trace "Successfully retrieved fwd page", len=outSeq.len, pagingInfo=outPagingInfo
  
  return (outSeq, outPagingInfo, outError)

proc bwdPage(storeQueue: StoreQueueRef,
             pred: QueryFilterMatcher,
             maxPageSize: uint64,
             startCursor: Option[Index]):
            (seq[WakuMessage], PagingInfo, HistoryResponseError) =
  ## Populate a single page in backward direction
  ## Start at `startCursor` (exclusive), or last entry (inclusive) if not defined.
  ## Page size must not exceed `maxPageSize`
  ## Each entry must match the `pred`
  
  trace "Retrieving bwd page from store queue", len=storeQueue.items.len, maxPageSize=maxPageSize, startCursor=startCursor
  
  var
    outSeq: seq[WakuMessage]
    outPagingInfo: PagingInfo
    outError: HistoryResponseError
  
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    currentEntry: SortedSetResult[Index, IndexedWakuMessage]
    lastValidCursor: Index
  
  # Find starting entry
  if startCursor.isSome():
    lastValidCursor = startCursor.get()

    let cursorEntry = w.rwdToCursor(startCursor.get())
    if cursorEntry.isErr():
      # Quick exit here if start cursor not found
      trace "Could not find starting cursor. Returning empty result.", startCursor=startCursor
      outSeq = @[]
      outPagingInfo = PagingInfo(pageSize: 0, cursor: startCursor.get(), direction: PagingDirection.BACKWARD)
      outError = HistoryResponseError.INVALID_CURSOR
      w.destroy
      return (outSeq, outPagingInfo, outError)

    # Step walker one more step back
    currentEntry = w.prev
  else:
    # Start from the back of the queue
    lastValidCursor = Index() # No valid (only empty) last cursor
    currentEntry = w.last
  
  trace "Starting bwd page query", currentEntry=currentEntry

  ## This loop walks backward over the queue:
  ## 1. from the given cursor (or last entry, if not provided)
  ## 2. adds entries matching the predicate function to output page
  ## 3. until either the beginning of the queue or maxPageSize is reached
  var numberOfItems = 0.uint
  while currentEntry.isOk() and numberOfItems < maxPageSize:
    trace "Continuing bwd page query", currentEntry=currentEntry, numberOfItems=numberOfItems

    if pred(currentEntry.value.data):
      trace "Current item matches predicate. Adding to output."
      lastValidCursor = currentEntry.value.key
      outSeq.add(currentEntry.value.data.msg)
      numberOfItems += 1
    currentEntry = w.prev
  w.destroy

  outPagingInfo = PagingInfo(pageSize: outSeq.len.uint,
                             cursor: lastValidCursor,
                             direction: PagingDirection.BACKWARD)
  outError = HistoryResponseError.NONE

  trace "Successfully retrieved bwd page", len=outSeq.len, pagingInfo=outPagingInfo

  return (outSeq.reversed(), # Even if paging backwards, each page should be in forward order
          outPagingInfo,
          outError)


#### API

proc new*(T: type StoreQueueRef, capacity: int = StoreQueueDefaultMaxCapacity): T =
  var items = SortedSet[Index, IndexedWakuMessage].init()
  return StoreQueueRef(items: items, capacity: capacity)


proc contains*(store: StoreQueueRef, index: Index): bool =
  ## Return `true` if the store queue already contains the `index`, `false` otherwise.
  store.items.eq(index).isOk()

proc len*(store: StoreQueueRef): int {.noSideEffect.} =
  store.items.len

proc `$`*(store: StoreQueueRef): string =
  $store.items


## --- SortedSet accessors ---

iterator fwdIterator*(storeQueue: StoreQueueRef): (Index, IndexedWakuMessage) =
  ## Forward iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    res = w.first()

  while res.isOk():
    yield (res.value.key, res.value.data)
    res = w.next()

  w.destroy()

iterator bwdIterator*(storeQueue: StoreQueueRef): (Index, IndexedWakuMessage) =
  ## Backwards iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    res = w.last()

  while res.isOk():
    yield (res.value.key, res.value.data)
    res = w.prev()

  w.destroy()

proc first*(store: StoreQueueRef): MessageStoreResult[IndexedWakuMessage] =
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(store.items)
    res = w.first()
  w.destroy()

  if res.isErr():
    return err("Not found")

  return ok(res.value.data)

proc last*(storeQueue: StoreQueueRef): MessageStoreResult[IndexedWakuMessage] =
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    res = w.last()
  w.destroy()

  if res.isErr():
    return err("Not found")

  return ok(res.value.data)


## --- Queue API ---

proc add*(store: StoreQueueRef, msg: IndexedWakuMessage): MessageStoreResult[void] =
  ## Add a message to the queue
  ## 
  ## If we're at capacity, we will be removing, the oldest (first) item
  trace "adding item to store queue", msg=msg

  # Ensure that messages don't "jump" to the front of the queue with future timestamps
  if msg.index.senderTime - msg.index.receiverTime > StoreMaxTimeVariance:
    return err("future_sender_timestamp")

  if store.contains(msg.index):
    trace "could not add item to store queue. Index already exists", index=msg.index
    return err("duplicate")


  # TODO: the below delete block can be removed if we convert to circular buffer
  if store.items.len >= store.capacity:
    var
      w = SortedSetWalkRef[Index, IndexedWakuMessage].init(store.items)
      firstItem = w.first

    if cmp(msg.index, firstItem.value.key) < 0:
      # When at capacity, we won't add if message index is smaller (older) than our oldest item
      w.destroy # Clean up walker
      return err("too_old")

    discard store.items.delete(firstItem.value.key)
    w.destroy # better to destroy walker after a delete operation
  
  store.items.insert(msg.index).value.data = msg

  return ok()

method put*(store: StoreQueueRef, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] =
  let message = IndexedWakuMessage(msg: message, index: cursor, pubsubTopic: pubsubTopic)
  store.add(message)


proc getPage*(storeQueue: StoreQueueRef,
              pred: QueryFilterMatcher,
              pagingInfo: PagingInfo):
             (seq[WakuMessage], PagingInfo, HistoryResponseError) {.gcsafe.} =
  ## Get a single page of history matching the predicate and
  ## adhering to the pagingInfo parameters
  
  trace "getting page from store queue", len=storeQueue.items.len, pagingInfo=pagingInfo
  
  let
    cursorOpt = if pagingInfo.cursor == Index(): none(Index) ## TODO: pagingInfo.cursor should be an Option. We shouldn't rely on empty initialisation to determine if set or not!
                else: some(pagingInfo.cursor)
    maxPageSize = if pagingInfo.pageSize <= 0: MaxPageSize 
                  else: min(pagingInfo.pageSize, MaxPageSize)
  
  case pagingInfo.direction
    of PagingDirection.FORWARD:
      return storeQueue.fwdPage(pred, maxPageSize, cursorOpt)
    of PagingDirection.BACKWARD:
      return storeQueue.bwdPage(pred, maxPageSize, cursorOpt)

proc getPage*(storeQueue: StoreQueueRef,
              pagingInfo: PagingInfo):
             (seq[WakuMessage], PagingInfo, HistoryResponseError) {.gcsafe.} =
  ## Get a single page of history without filtering.
  ## Adhere to the pagingInfo parameters
  
  proc predicate(i: IndexedWakuMessage): bool = true # no filtering

  return getPage(storeQueue, predicate, pagingInfo)


method getMessagesByHistoryQuery*(
  store: StoreQueueRef,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(Index),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = MaxPageSize,
  ascendingOrder = true
): MessageStoreResult[MessageStorePage] =

  proc matchesQuery(indMsg: IndexedWakuMessage): bool =
    trace "Matching indexed message against predicate", msg=indMsg

    if pubsubTopic.isSome():
      # filter by pubsub topic
      if indMsg.pubsubTopic != pubsubTopic.get():
        trace "Failed to match pubsub topic", criteria=pubsubTopic.get(), actual=indMsg.pubsubTopic
        return false
    
    if startTime.isSome() and endTime.isSome():
      # temporal filtering: select only messages whose sender generated timestamps fall 
      # between the queried start time and end time
      if indMsg.msg.timestamp > endTime.get() or indMsg.msg.timestamp < startTime.get():
        trace "Failed to match temporal filter", criteriaStart=startTime.get(), criteriaEnd=endTime.get(), actual=indMsg.msg.timestamp
        return false
    
    if contentTopic.isSome():
      # filter by content topic
      if indMsg.msg.contentTopic notin contentTopic.get():
        trace "Failed to match content topic", criteria=contentTopic.get(), actual=indMsg.msg.contentTopic
        return false
    
    return true


  let queryPagingInfo = PagingInfo(
    pageSize: maxPageSize,
    cursor: cursor.get(Index()),
    direction: if ascendingOrder: PagingDirection.FORWARD
               else: PagingDirection.BACKWARD
  )
  let (messages, pagingInfo, error) = store.getPage(matchesQuery, queryPagingInfo)

  if error == HistoryResponseError.INVALID_CURSOR:
    return err("invalid cursor")

  if messages.len == 0:
    return ok((messages, none(PagingInfo)))
  
  ok((messages, some(pagingInfo)))


method getMessagesCount*(s: StoreQueueRef): MessageStoreResult[int64] =
  ok(int64(s.len()))

method getOldestMessageTimestamp*(s: StoreQueueRef): MessageStoreResult[Timestamp] =
  s.first().map(proc(msg: IndexedWakuMessage): Timestamp = msg.index.receiverTime)

method getNewestMessageTimestamp*(s: StoreQueueRef): MessageStoreResult[Timestamp] =
  s.last().map(proc(msg: IndexedWakuMessage): Timestamp = msg.index.receiverTime)


method deleteMessagesOlderThanTimestamp*(s: StoreQueueRef, ts: Timestamp): MessageStoreResult[void] =
  # TODO: Implement this message_store method
  err("interface method not implemented")

method deleteOldestMessagesNotWithinLimit*(s: StoreQueueRef, limit: int): MessageStoreResult[void] =
  # TODO: Implement this message_store method
  err("interface method not implemented")