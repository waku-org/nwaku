when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results, 
  stew/sorted_set,
  chronicles
import
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/common,
  ../../../protocol/waku_store/message_store,
  ../../../utils/time,
  ./index


logScope:
  topics = "waku node message_store storequeue"


const StoreQueueDefaultMaxCapacity* = 25_000


type
  IndexedWakuMessage* = object
    # TODO: may need to rename this object as it holds both the index and the pubsub topic of a waku message
    ## This type is used to encapsulate a WakuMessage and its Index
    msg*: WakuMessage
    index*: Index
    pubsubTopic*: string
    
  QueryFilterMatcher = proc(indexedWakuMsg: IndexedWakuMessage): bool {.gcsafe, closure.}

type
  StoreQueueErrorKind {.pure.} = enum
    INVALID_CURSOR

  StoreQueueGetPageResult = Result[seq[MessageStoreRow], StoreQueueErrorKind]


type StoreQueueRef* = ref object of MessageStore
    ## Bounded repository for indexed messages
    ## 
    ## The store queue will keep messages up to its
    ## configured capacity. As soon as this capacity
    ## is reached and a new message is added, the oldest
    ## item will be removed to make space for the new one.
    ## This implies both a `delete` and `add` operation
    ## for new items.
    ## 
    ## TODO: a circular/ring buffer may be a more efficient implementation
    ## TODO: we don't need to store the Index twice (as key and in the value)
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
  while nextItem.isOk():
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
  
  while prevItem.isOk():
    if prevItem.value.key == startCursor:
      # Exit rwd loop when we find the start cursor
      break

    # Not yet at cursor. Continue rewinding.
    prevItem = w.prev
    trace "Continuing rewind to start cursor", prevItem=prevItem
  
  return prevItem


#### API

proc new*(T: type StoreQueueRef, capacity: int = StoreQueueDefaultMaxCapacity): T =
  var items = SortedSet[Index, IndexedWakuMessage].init()
  return StoreQueueRef(items: items, capacity: capacity)


proc contains*(store: StoreQueueRef, index: Index): bool =
  ## Return `true` if the store queue already contains the `index`, `false` otherwise.
  store.items.eq(index).isOk()

proc len*(store: StoreQueueRef): int {.noSideEffect.} =
  store.items.len

proc getPage(store: StoreQueueRef,
             pageSize: uint64 = 0,
             forward: bool = true,
             cursor: Option[Index] = none(Index),
             predicate: QueryFilterMatcher = nil): StoreQueueGetPageResult =
  ## Populate a single page in forward direction
  ## Start at the `startCursor` (exclusive), or first entry (inclusive) if not defined.
  ## Page size must not exceed `maxPageSize`
  ## Each entry must match the `pred`
  var outSeq: seq[MessageStoreRow]
  
  var w = SortedSetWalkRef[Index,IndexedWakuMessage].init(store.items)
  defer: w.destroy()

  var currentEntry: SortedSetResult[Index, IndexedWakuMessage]
  
  # Find starting entry
  if cursor.isSome():
    let cursorEntry = if forward: w.ffdToCursor(cursor.get())
                      else: w.rwdToCursor(cursor.get())
    if cursorEntry.isErr():
      return err(StoreQueueErrorKind.INVALID_CURSOR)
    
    # Advance walker once more
    currentEntry = if forward: w.next()
                   else: w.prev()
  else:
    # Start from the beginning of the queue
    currentEntry = if forward: w.first()
                   else: w.last()

  trace "Starting page query", currentEntry=currentEntry

  ## This loop walks forward over the queue:
  ## 1. from the given cursor (or first/last entry, if not provided)
  ## 2. adds entries matching the predicate function to output page
  ## 3. until either the end of the queue or maxPageSize is reached
  var numberOfItems = 0.uint
  while currentEntry.isOk() and numberOfItems < pageSize:
    trace "Continuing page query", currentEntry=currentEntry, numberOfItems=numberOfItems
    
    if predicate.isNil() or predicate(currentEntry.value.data):
      let 
        key = currentEntry.value.key
        data = currentEntry.value.data
      
      numberOfItems += 1

      outSeq.add((key.pubsubTopic, data.msg, @(key.digest.data), key.receiverTime))

    currentEntry = if forward: w.next()
                   else: w.prev()

  trace "Successfully retrieved page", len=outSeq.len
  
  return ok(outSeq)


## --- SortedSet accessors ---

iterator fwdIterator*(store: StoreQueueRef): (Index, IndexedWakuMessage) =
  ## Forward iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(store.items)
    res = w.first()

  while res.isOk():
    yield (res.value.key, res.value.data)
    res = w.next()

  w.destroy()

iterator bwdIterator*(store: StoreQueueRef): (Index, IndexedWakuMessage) =
  ## Backwards iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(store.items)
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

proc last*(store: StoreQueueRef): MessageStoreResult[IndexedWakuMessage] =
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(store.items)
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


method put*(store: StoreQueueRef, pubsubTopic: PubsubTopic, message: WakuMessage, digest: MessageDigest, receivedTime: Timestamp): MessageStoreResult[void] =
  let index = Index(pubsubTopic: pubsubTopic, senderTime: message.timestamp, receiverTime: receivedTime, digest: digest)
  let message = IndexedWakuMessage(msg: message, index: index, pubsubTopic: pubsubTopic)
  store.add(message)

method put*(store: StoreQueueRef, pubsubTopic: PubsubTopic, message: WakuMessage): MessageStoreResult[void] =
  ## Inserts a message into the store
  procCall MessageStore(store).put(pubsubTopic, message)


method getAllMessages*(store: StoreQueueRef): MessageStoreResult[seq[MessageStoreRow]] =
  # TODO: Implement this message_store method
  err("interface method not implemented")

method getMessagesByHistoryQuery*(
  store: StoreQueueRef,
  contentTopic = none(seq[ContentTopic]),
  pubsubTopic = none(PubsubTopic),
  cursor = none(HistoryCursor),
  startTime = none(Timestamp),
  endTime = none(Timestamp),
  maxPageSize = DefaultPageSize,
  ascendingOrder = true
): MessageStoreResult[seq[MessageStoreRow]] =
  let cursor = cursor.map(toIndex)

  let matchesQuery: QueryFilterMatcher = proc(indMsg: IndexedWakuMessage): bool =
    if pubsubTopic.isSome():
      if indMsg.pubsubTopic != pubsubTopic.get():
        return false
    
    if startTime.isSome() and endTime.isSome():
      # temporal filtering: select only messages whose sender generated timestamps fall 
      # between the queried start time and end time
      if indMsg.msg.timestamp > endTime.get() or indMsg.msg.timestamp < startTime.get():
        return false
    
    if contentTopic.isSome():
      if indMsg.msg.contentTopic notin contentTopic.get():
        return false
    
    return true

  var pageRes: StoreQueueGetPageResult
  try:
    pageRes = store.getPage(maxPageSize, ascendingOrder, cursor, matchesQuery)
  except:
    return err(getCurrentExceptionMsg())

  if pageRes.isErr():
    case pageRes.error:
    of StoreQueueErrorKind.INVALID_CURSOR:
      return err("invalid cursor")
  
  ok(pageRes.value)


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