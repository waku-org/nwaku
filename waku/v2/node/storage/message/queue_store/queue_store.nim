{.push raises: [Defect].}

import
  std/[options, algorithm, times],
  stew/[results, sorted_set],
  chronicles
import
  ../../../../protocol/waku_message,
  ../../../../protocol/waku_store/rpc,
  ../../../../protocol/waku_store/pagination,
  ../../../../protocol/waku_store/message_store,
  ../../../../utils/time,
  ./index


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
    
  QueryFilterMatcher = proc(indexedWakuMsg: IndexedWakuMessage) : bool {.gcsafe, closure.}

  StoreQueueGetPageResult = Result[(seq[WakuMessage], PagingInfo), HistoryResponseError]

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

proc getPage(storeQueue: StoreQueueRef,
             pred: QueryFilterMatcher,
             maxPageSize: uint64,
             forward: bool,
             startCursor: Option[Index]): StoreQueueGetPageResult =
  ## Populate a single page in forward direction
  ## Start at the `startCursor` (exclusive), or first entry (inclusive) if not defined.
  ## Page size must not exceed `maxPageSize`
  ## Each entry must match the `pred`
  
  trace "Retrieving page from store queue", len=storeQueue.items.len, maxPageSize=maxPageSize, startCursor=startCursor, forward=forward
  
  var
    outSeq: seq[WakuMessage]
    outPagingInfo: PagingInfo
  
  var w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
  defer: w.destroy()
    
  var
    currentEntry: SortedSetResult[Index, IndexedWakuMessage]
    lastValidCursor: Index
  
  # Find starting entry
  if startCursor.isSome():
    lastValidCursor = startCursor.get()

    let cursorEntry = if forward: w.ffdToCursor(startCursor.get())
                      else: w.rwdToCursor(startCursor.get())
    if cursorEntry.isErr():
      # Quick exit here if start cursor not found
      trace "Starting cursor not found", startCursor=startCursor.get()
      return err(HistoryResponseError.INVALID_CURSOR)
    
    # Advance walker once more
    currentEntry = if forward: w.next()
                   else: w.prev()
  else:
    # Start from the beginning of the queue
    lastValidCursor = Index() # No valid (only empty) last cursor
    currentEntry = if forward: w.first()
                   else: w.last()

  trace "Starting page query", currentEntry=currentEntry

  ## This loop walks forward over the queue:
  ## 1. from the given cursor (or first/last entry, if not provided)
  ## 2. adds entries matching the predicate function to output page
  ## 3. until either the end of the queue or maxPageSize is reached
  var numberOfItems = 0.uint
  while currentEntry.isOk() and numberOfItems < maxPageSize:
    trace "Continuing page query", currentEntry=currentEntry, numberOfItems=numberOfItems
    
    if pred(currentEntry.value.data):
      lastValidCursor = currentEntry.value.key
      outSeq.add(currentEntry.value.data.msg)
      numberOfItems += 1

    currentEntry = if forward: w.next()
                   else: w.prev()

  trace "Successfully retrieved page", len=outSeq.len

  outPagingInfo = PagingInfo(pageSize: outSeq.len.uint,
                             cursor: lastValidCursor.toPagingIndex(),
                             direction: if forward: PagingDirection.FORWARD
                                        else: PagingDirection.BACKWARD)

  # Even if paging backwards, each page should be in forward order
  if not forward:
      outSeq.reverse() 
  
  return ok((outSeq, outPagingInfo))


#### API

proc new*(T: type StoreQueueRef, capacity: int = StoreQueueDefaultMaxCapacity): T =
  var items = SortedSet[Index, IndexedWakuMessage].init()
  return StoreQueueRef(items: items, capacity: capacity)


proc contains*(store: StoreQueueRef, index: Index): bool =
  ## Return `true` if the store queue already contains the `index`, `false` otherwise.
  store.items.eq(index).isOk()

proc len*(store: StoreQueueRef): int {.noSideEffect.} =
  store.items.len


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


method put*(store: StoreQueueRef, pubsubTopic: string, message: WakuMessage, digest: MessageDigest, receivedTime: Timestamp): MessageStoreResult[void] =
  let index = Index(pubsubTopic: pubsubTopic, senderTime: message.timestamp, receiverTime: receivedTime, digest: digest)
  let message = IndexedWakuMessage(msg: message, index: index, pubsubTopic: pubsubTopic)
  store.add(message)

method put*(store: StoreQueueRef, pubsubTopic: string, message: WakuMessage): MessageStoreResult[void] =
  let 
    now = getNanosecondTime(getTime().toUnixFloat())
    digest = computeDigest(message)
  store.put(pubsubTopic, message, digest, now)


proc getPage*(storeQueue: StoreQueueRef,
              pred: QueryFilterMatcher,
              pagingInfo: PagingInfo): StoreQueueGetPageResult {.gcsafe.} =
  ## Get a single page of history matching the predicate and
  ## adhering to the pagingInfo parameters
  
  trace "getting page from store queue", len=storeQueue.items.len, pagingInfo=pagingInfo
  
  let
    cursorOpt = if pagingInfo.cursor == PagingIndex(): none(Index) ## TODO: pagingInfo.cursor should be an Option. We shouldn't rely on empty initialisation to determine if set or not!
                else: some(pagingInfo.cursor.toIndex())
    maxPageSize = pagingInfo.pageSize

  let forward = pagingInfo.direction == PagingDirection.FORWARD
  return storeQueue.getPage(pred, maxPageSize, forward, cursorOpt)

proc getPage*(storeQueue: StoreQueueRef, pagingInfo: PagingInfo): StoreQueueGetPageResult {.gcsafe.} =
  ## Get a single page of history without filtering.
  ## Adhere to the pagingInfo parameters
  
  proc predicate(i: IndexedWakuMessage): bool = true # no filtering

  return getPage(storeQueue, predicate, pagingInfo)


method getMessagesByHistoryQuery*(
  store: StoreQueueRef,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(string),
  cursor = none(PagingIndex),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = DefaultPageSize,
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
    cursor: cursor.get(PagingIndex()),
    direction: if ascendingOrder: PagingDirection.FORWARD
               else: PagingDirection.BACKWARD
  )
  let getPageRes = store.getPage(matchesQuery, queryPagingInfo)
  if getPageRes.isErr():
    return err("invalid cursor")

  let (messages, pagingInfo) = getPageRes.value
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