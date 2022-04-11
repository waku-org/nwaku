## Types for waku_store protocol.

{.push raises: [Defect].}

# Group by std, external then internal imports
import
  std/[algorithm, options],
  # external imports
  bearssl,
  chronicles,
  libp2p/protocols/protocol,
  stew/[results, sorted_set],
  # internal imports
  ../../node/storage/message/message_store,
  ../../utils/pagination,
  ../../utils/time,
  ../../node/peer_manager/peer_manager,
  ../waku_swap/waku_swap_types,
  ../waku_message

# export all modules whose types are used in public functions/types
export 
  bearssl,
  results,
  peer_manager,
  waku_swap_types,
  message_store,
  waku_message,
  pagination

const
  # Constants required for pagination -------------------------------------------
  MaxPageSize* = uint64(100) # Maximum number of waku messages in each page
  # TODO the DefaultPageSize can be changed, it's current value is random
  DefaultPageSize* = uint64(20) # A recommended default number of waku messages per page

  MaxRpcSize* = MaxPageSize * MaxWakuMessageSize + 64*1024 # We add a 64kB safety buffer for protocol overhead

  MaxTimeVariance* = getNanoSecondTime(20) # 20 seconds maximum allowable sender timestamp "drift" into the future

  DefaultTopic* = "/waku/2/default-waku/proto"


type
  HistoryContentFilter* = object
    contentTopic*: ContentTopic

  QueryHandlerFunc* = proc(response: HistoryResponse) {.gcsafe, closure.}

  QueryFilterMatcher* = proc(indexedWakuMsg: IndexedWakuMessage) : bool {.gcsafe, closure.}

  IndexedWakuMessage* = object
    # TODO may need to rename this object as it holds both the index and the pubsub topic of a waku message
    ## This type is used to encapsulate a WakuMessage and its Index
    msg*: WakuMessage
    index*: Index
    pubsubTopic*: string

  PagingDirection* {.pure.} = enum
    ## PagingDirection determines the direction of pagination
    BACKWARD = uint32(0)
    FORWARD = uint32(1)

  PagingInfo* = object
    ## This type holds the information needed for the pagination
    pageSize*: uint64
    cursor*: Index
    direction*: PagingDirection

  HistoryQuery* = object
    contentFilters*: seq[HistoryContentFilter]
    pubsubTopic*: string
    pagingInfo*: PagingInfo # used for pagination
    startTime*: Timestamp # used for time-window query
    endTime*: Timestamp # used for time-window query

  HistoryResponseError* {.pure.} = enum
    ## HistoryResponseError contains error message to inform  the querying node about the state of its request
    NONE = uint32(0)
    INVALID_CURSOR = uint32(1)

  HistoryResponse* = object
    messages*: seq[WakuMessage]
    pagingInfo*: PagingInfo # used for pagination
    error*: HistoryResponseError

  HistoryRPC* = object
    requestId*: string
    query*: HistoryQuery
    response*: HistoryResponse

  QueryResult* = Result[uint64, string]
  MessagesResult* = Result[seq[WakuMessage], string]

  StoreQueueRef* = ref object
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

  StoreQueueResult*[T] = Result[T, cstring]
  
  WakuStore* = ref object of LPProtocol
    peerManager*: PeerManager
    rng*: ref BrHmacDrbgContext
    messages*: StoreQueueRef # in-memory message store
    store*: MessageStore  # sqlite DB handle
    wakuSwap*: WakuSwap
    persistMessages*: bool

######################
# StoreQueue helpers #
######################

logScope:
  topics = "wakustorequeue"

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
    if cursorEntry.isErr:
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
  while currentEntry.isOk and numberOfItems < maxPageSize:

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

##################
# StoreQueue API #
##################

## --- SortedSet accessors ---

iterator fwdIterator*(storeQueue: StoreQueueRef): (Index, IndexedWakuMessage) =
  ## Forward iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    res = w.first
  while res.isOk:
    yield (res.value.key, res.value.data)
    res = w.next
  w.destroy

iterator bwdIterator*(storeQueue: StoreQueueRef): (Index, IndexedWakuMessage) =
  ## Backwards iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    res = w.last
  while res.isOk:
    yield (res.value.key, res.value.data)
    res = w.prev
  w.destroy

proc first*(storeQueue: StoreQueueRef): StoreQueueResult[IndexedWakuMessage] =
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    res = w.first
  w.destroy

  if res.isOk:
    return ok(res.value.data)
  else:
    return err("Not found")

proc last*(storeQueue: StoreQueueRef): StoreQueueResult[IndexedWakuMessage] =
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(storeQueue.items)
    res = w.last
  w.destroy

  if res.isOk:
    return ok(res.value.data)
  else:
    return err("Not found")

## --- Queue API ---

proc new*(T: type StoreQueueRef, capacity: int): T =
  var items = SortedSet[Index, IndexedWakuMessage].init()

  return StoreQueueRef(items: items, capacity: capacity)

proc add*(storeQueue: StoreQueueRef, msg: IndexedWakuMessage): StoreQueueResult[void] =
  ## Add a message to the queue
  ## If we're at capacity, we will be removing,
  ## the oldest (first) item
  
  # Ensure that messages don't "jump" to the front of the queue with future timestamps
  if msg.index.senderTime - msg.index.receiverTime > MaxTimeVariance:
    return err("future_sender_timestamp")
  
  trace "Adding item to store queue", msg=msg

  # TODO the below delete block can be removed if we convert to circular buffer
  if storeQueue.items.len >= storeQueue.capacity:
    var
      w = SortedSetWalkRef[Index, IndexedWakuMessage].init(storeQueue.items)
      firstItem = w.first

    if cmp(msg.index, firstItem.value.key) < 0:
      # When at capacity, we won't add if message index is smaller (older) than our oldest item
      w.destroy # Clean up walker
      return err("too_old")

    discard storeQueue.items.delete(firstItem.value.key)
    w.destroy # better to destroy walker after a delete operation
  
  let res = storeQueue.items.insert(msg.index)
  if res.isErr:
    # This indicates the index already exists in the storeQueue.
    # TODO: could return error result and log in metrics

    trace "Could not add item to store queue. Index already exists.", index=msg.index
    return err("duplicate")
  else:
    res.value.data = msg
  
  trace "Successfully added item to store queue.", msg=msg
  return ok()

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
    maxPageSize = if pagingInfo.pageSize == 0 or pagingInfo.pageSize > MaxPageSize: MaxPageSize # Used default MaxPageSize for invalid pagingInfos
                  else: pagingInfo.pageSize
  
  case pagingInfo.direction
    of FORWARD:
      return storeQueue.fwdPage(pred, maxPageSize, cursorOpt)
    of BACKWARD:
      return storeQueue.bwdPage(pred, maxPageSize, cursorOpt)

proc getPage*(storeQueue: StoreQueueRef,
              pagingInfo: PagingInfo):
             (seq[WakuMessage], PagingInfo, HistoryResponseError) {.gcsafe.} =
  ## Get a single page of history without filtering.
  ## Adhere to the pagingInfo parameters
  
  proc predicate(i: IndexedWakuMessage): bool = true # no filtering

  return getPage(storeQueue, predicate, pagingInfo)

proc contains*(storeQueue: StoreQueueRef, index: Index): bool =
  ## Return `true` if the store queue already contains the `index`,
  ## `false` otherwise
  let res = storeQueue.items.eq(index)

  return res.isOk()

proc len*(storeQueue: StoreQueueRef): int {.noSideEffect.} =
  storeQueue.items.len

proc `$`*(storeQueue: StoreQueueRef): string =
  $(storeQueue.items)
