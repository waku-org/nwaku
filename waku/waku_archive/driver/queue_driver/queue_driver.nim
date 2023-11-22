when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  stew/sorted_set,
  chronicles,
  chronos
import
  ../../../waku_core,
  ../../common,
  ../../driver,
  ./index

logScope:
  topics = "waku archive queue_store"

const QueueDriverDefaultMaxCapacity* = 25_000

type
  IndexedWakuMessage = object
    # TODO: may need to rename this object as it holds both the index and the pubsub topic of a waku message
    ## This type is used to encapsulate a WakuMessage and its Index
    msg*: WakuMessage
    index*: Index
    pubsubTopic*: string

  QueryFilterMatcher = proc(indexedWakuMsg: IndexedWakuMessage): bool {.gcsafe, closure.}

type
  QueueDriverErrorKind {.pure.} = enum
    INVALID_CURSOR

  QueueDriverGetPageResult = Result[seq[ArchiveRow], QueueDriverErrorKind]

proc `$`(error: QueueDriverErrorKind): string =
  case error:
  of INVALID_CURSOR:
    "invalid_cursor"

type QueueDriver* = ref object of ArchiveDriver
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

proc walkToCursor(w: SortedSetWalkRef[Index, IndexedWakuMessage],
                  startCursor: Index,
                  forward: bool): SortedSetResult[Index, IndexedWakuMessage] =
  ## Walk to util we find the cursor
  ## TODO: Improve performance here with a binary/tree search

  var nextItem = if forward: w.first()
                 else: w.last()

  ## Fast forward until we reach the startCursor
  while nextItem.isOk():
    if nextItem.value.key == startCursor:
      break

    # Not yet at cursor. Continue advancing
    nextItem = if forward: w.next()
               else: w.prev()

  return nextItem

#### API

proc new*(T: type QueueDriver, capacity: int = QueueDriverDefaultMaxCapacity): T =
  var items = SortedSet[Index, IndexedWakuMessage].init()
  return QueueDriver(items: items, capacity: capacity)

proc contains*(driver: QueueDriver, index: Index): bool =
  ## Return `true` if the store queue already contains the `index`, `false` otherwise.
  driver.items.eq(index).isOk()

proc len*(driver: QueueDriver): int {.noSideEffect.} =
  driver.items.len

proc getPage(driver: QueueDriver,
             pageSize: uint = 0,
             forward: bool = true,
             cursor: Option[Index] = none(Index),
             predicate: QueryFilterMatcher = nil): QueueDriverGetPageResult =
  ## Populate a single page in forward direction
  ## Start at the `startCursor` (exclusive), or first entry (inclusive) if not defined.
  ## Page size must not exceed `maxPageSize`
  ## Each entry must match the `pred`
  var outSeq: seq[ArchiveRow]

  var w = SortedSetWalkRef[Index,IndexedWakuMessage].init(driver.items)
  defer: w.destroy()

  var currentEntry: SortedSetResult[Index, IndexedWakuMessage]

  # Find starting entry
  if cursor.isSome():
    let cursorEntry = w.walkToCursor(cursor.get(), forward)
    if cursorEntry.isErr():
      return err(QueueDriverErrorKind.INVALID_CURSOR)

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
  var numberOfItems: uint = 0
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

iterator fwdIterator*(driver: QueueDriver): (Index, IndexedWakuMessage) =
  ## Forward iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(driver.items)
    res = w.first()

  while res.isOk():
    yield (res.value.key, res.value.data)
    res = w.next()

  w.destroy()

iterator bwdIterator*(driver: QueueDriver): (Index, IndexedWakuMessage) =
  ## Backwards iterator over the entire store queue
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(driver.items)
    res = w.last()

  while res.isOk():
    yield (res.value.key, res.value.data)
    res = w.prev()

  w.destroy()

proc first*(driver: QueueDriver): ArchiveDriverResult[IndexedWakuMessage] =
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(driver.items)
    res = w.first()
  w.destroy()

  if res.isErr():
    return err("Not found")

  return ok(res.value.data)

proc last*(driver: QueueDriver): ArchiveDriverResult[IndexedWakuMessage] =
  var
    w = SortedSetWalkRef[Index,IndexedWakuMessage].init(driver.items)
    res = w.last()
  w.destroy()

  if res.isErr():
    return err("Not found")

  return ok(res.value.data)

## --- Queue API ---

proc add*(driver: QueueDriver, msg: IndexedWakuMessage): ArchiveDriverResult[void] =
  ## Add a message to the queue
  ##
  ## If we're at capacity, we will be removing, the oldest (first) item
  if driver.contains(msg.index):
    trace "could not add item to store queue. Index already exists", index=msg.index
    return err("duplicate")

  # TODO: the below delete block can be removed if we convert to circular buffer
  if driver.items.len >= driver.capacity:
    var
      w = SortedSetWalkRef[Index, IndexedWakuMessage].init(driver.items)
      firstItem = w.first

    if cmp(msg.index, firstItem.value.key) < 0:
      # When at capacity, we won't add if message index is smaller (older) than our oldest item
      w.destroy # Clean up walker
      return err("too_old")

    discard driver.items.delete(firstItem.value.key)
    w.destroy # better to destroy walker after a delete operation

  driver.items.insert(msg.index).value.data = msg

  return ok()

method put*(driver: QueueDriver,
            pubsubTopic: PubsubTopic,
            message: WakuMessage,
            digest: MessageDigest,
            messageHash: WakuMessageHash,
            receivedTime: Timestamp):
            Future[ArchiveDriverResult[void]] {.async.} =
  let index = Index(pubsubTopic: pubsubTopic, senderTime: message.timestamp, receiverTime: receivedTime, digest: digest)
  let message = IndexedWakuMessage(msg: message, index: index, pubsubTopic: pubsubTopic)
  return driver.add(message)

method getAllMessages*(driver: QueueDriver):
                       Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.} =
  # TODO: Implement this message_store method
  return err("interface method not implemented")

method getMessages*(driver: QueueDriver,
                    contentTopic: seq[ContentTopic] = @[],
                    pubsubTopic = none(PubsubTopic),
                    cursor = none(ArchiveCursor),
                    startTime = none(Timestamp),
                    endTime = none(Timestamp),
                    maxPageSize = DefaultPageSize,
                    ascendingOrder = true):
                    Future[ArchiveDriverResult[seq[ArchiveRow]]] {.async.}=
  let cursor = cursor.map(toIndex)

  let matchesQuery: QueryFilterMatcher = func(row: IndexedWakuMessage): bool =
    if pubsubTopic.isSome() and row.pubsubTopic != pubsubTopic.get():
      return false

    if contentTopic.len > 0 and row.msg.contentTopic notin contentTopic:
      return false

    if startTime.isSome() and row.msg.timestamp < startTime.get():
      return false

    if endTime.isSome() and row.msg.timestamp > endTime.get():
      return false

    return true

  var pageRes: QueueDriverGetPageResult
  try:
    pageRes = driver.getPage(maxPageSize, ascendingOrder, cursor, matchesQuery)
  except CatchableError, Exception:
    return err(getCurrentExceptionMsg())

  if pageRes.isErr():
    return err($pageRes.error)

  return ok(pageRes.value)

method getMessagesCount*(driver: QueueDriver):
                         Future[ArchiveDriverResult[int64]] {.async} =
  return ok(int64(driver.len()))

method getPagesCount*(driver: QueueDriver):
                         Future[ArchiveDriverResult[int64]] {.async} =
  return ok(int64(driver.len()))

method getPagesSize*(driver: QueueDriver):
                         Future[ArchiveDriverResult[int64]] {.async} =
  return ok(int64(driver.len()))

method performVacuum*(driver: QueueDriver):
              Future[ArchiveDriverResult[void]] {.async.} =
  return err("interface method not implemented")

method getOldestMessageTimestamp*(driver: QueueDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return driver.first().map(proc(msg: IndexedWakuMessage): Timestamp = msg.index.receiverTime)

method getNewestMessageTimestamp*(driver: QueueDriver):
                                  Future[ArchiveDriverResult[Timestamp]] {.async.} =
  return driver.last().map(proc(msg: IndexedWakuMessage): Timestamp = msg.index.receiverTime)

method deleteMessagesOlderThanTimestamp*(driver: QueueDriver,
                                         ts: Timestamp):
                                         Future[ArchiveDriverResult[void]] {.async.} =
  # TODO: Implement this message_store method
  return err("interface method not implemented")

method deleteOldestMessagesNotWithinLimit*(driver: QueueDriver,
                                           limit: int):
                                           Future[ArchiveDriverResult[void]] {.async.} =
  # TODO: Implement this message_store method
  return err("interface method not implemented")

method close*(driver: QueueDriver):
              Future[ArchiveDriverResult[void]] {.async.} =
  return ok()
