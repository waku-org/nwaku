when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[times, options, sequtils, strutils, algorithm],
  stew/[results, byteutils],
  chronicles,
  chronos,
  metrics
import
  ../common/paging,
  ./driver,
  ./retention_policy,
  ../waku_core,
  ../waku_core/message/digest,
  ./common,
  ./archive_metrics

logScope:
  topics = "waku archive"

const
  #TODO if waku message are 150KiB max are those numbers still appropriate???
  DefaultPageSize*: uint = 20 # 2.93 MiB
  MaxPageSize*: uint = 100 # 14.65 MiB

# Retention policy
const WakuArchiveDefaultRetentionPolicyInterval* = chronos.minutes(30)

# Metrics reporting
const WakuArchiveDefaultMetricsReportInterval* = chronos.minutes(1)

# Message validation
# 20 seconds maximum allowable sender timestamp "drift"
const MaxMessageTimestampVariance* = getNanoSecondTime(20) 

## Archive

type WakuArchive* = ref object
  driver: ArchiveDriver

  retentionPolicy: Option[RetentionPolicy]

  retentionPolicyHandle: Future[void]
  metricsHandle: Future[void]

proc new*(T: type WakuArchive,
          driver: ArchiveDriver,
          retentionPolicy = none(RetentionPolicy)):
          Result[T, string] =
  if driver.isNil():
    return err("archive driver is Nil")

  let archive =
    WakuArchive(
      driver: driver,
      retentionPolicy: retentionPolicy,
    )

  return ok(archive)

proc validate*(self: WakuArchive, msg: WakuMessage): Result[void, string] =
  let
    now = getNanosecondTime(getTime().toUnixFloat())
    lowerBound = now - MaxMessageTimestampVariance
    upperBound = now + MaxMessageTimestampVariance

  if msg.timestamp < lowerBound:
    return err(invalidMessageOld)

  if upperBound < msg.timestamp:
    return err(invalidMessageFuture)

  ok()

proc handleMessage*(self: WakuArchive,
                    pubsubTopic: PubsubTopic,
                    msg: WakuMessage) {.async.} =
  if msg.ephemeral:
    # Ephemeral message, do not store
    return

  self.validate(msg).isOkOr:
    waku_archive_errors.inc(labelValues = [error])
    return

  let
    msgDigest = computeDigest(msg)
    msgHash = computeMessageHash(pubsubTopic, msg)

  trace "handling message",
    pubsubTopic=pubsubTopic,
    contentTopic=msg.contentTopic,
    timestamp=msg.timestamp,
    digest=toHex(msgDigest.data),
    messageHash=toHex(msgHash)
  
  let insertStartTime = getTime().toUnixFloat()

  (await self.driver.put(pubsubTopic, msg, msgDigest, msgHash, msg.timestamp)).isOkOr:
    waku_archive_errors.inc(labelValues = [insertFailure])
    # Prevent spamming the logs when multiple nodes are connected to the same database.
    # In that case, the message cannot be inserted but is an expected "insert error"
    # and therefore we reduce its visibility by having the log in trace level.
    if "duplicate key value violates unique constraint" in error:
      trace "failed to insert message", err=error
    else:
      debug "failed to insert message", err=error
    
  let insertDuration = getTime().toUnixFloat() - insertStartTime
  waku_archive_insert_duration_seconds.observe(insertDuration)

proc findMessages*(self: WakuArchive, query: ArchiveQuery): Future[ArchiveResult] {.async, gcsafe.} =
  ## Search the archive to return a single page of messages matching the query criteria
  
  let maxPageSize =
    if query.pageSize <= 0:
      DefaultPageSize
    else:
      min(query.pageSize, MaxPageSize)
    
  let isAscendingOrder = query.direction.into()

  if query.contentTopics.len > 10:
    return err(ArchiveError.invalidQuery("too many content topics"))

  let queryStartTime = getTime().toUnixFloat()

  let rows = (await self.driver.getMessages(
    contentTopic = query.contentTopics,
    pubsubTopic = query.pubsubTopic,
    cursor = query.cursor,
    startTime = query.startTime,
    endTime = query.endTime,
    hashes = query.hashes,
    maxPageSize = maxPageSize + 1,
    ascendingOrder = isAscendingOrder
  )).valueOr:
    return err(ArchiveError(kind: ArchiveErrorKind.DRIVER_ERROR, cause: error))

  let queryDuration = getTime().toUnixFloat() - queryStartTime
  waku_archive_query_duration_seconds.observe(queryDuration)

  var hashes = newSeq[WakuMessageHash]()
  var messages = newSeq[WakuMessage]()
  var cursor = none(ArchiveCursor)
  
  if rows.len == 0:
    return ok(ArchiveResponse(hashes: hashes, messages: messages, cursor: cursor))

  ## Messages
  let pageSize = min(rows.len, int(maxPageSize))
  
  #TODO once store v2 is removed, unzip instead of 2x map
  messages = rows[0..<pageSize].mapIt(it[1])
  hashes = rows[0..<pageSize].mapIt(it[4])

  ## Cursor
  if rows.len > int(maxPageSize):
    ## Build last message cursor
    ## The cursor is built from the last message INCLUDED in the response
    ## (i.e. the second last message in the rows list)
    
    #TODO Once Store v2 is removed keep only message and hash
    let (pubsubTopic, message, digest, storeTimestamp, hash) = rows[^2]

    #TODO Once Store v2 is removed, the cursor becomes the hash of the last message
    cursor = some(ArchiveCursor(
      digest: MessageDigest.fromBytes(digest),
      storeTime: storeTimestamp,
      sendertime: message.timestamp,
      pubsubTopic: pubsubTopic,
      hash: hash,
    ))

  # All messages MUST be returned in chronological order
  if not isAscendingOrder:
    reverse(messages)
    reverse(hashes)

  return ok(ArchiveResponse(hashes: hashes, messages: messages, cursor: cursor))

proc periodicRetentionPolicy(self: WakuArchive) {.async.} =
  debug "executing message retention policy"

  let policy = self.retentionPolicy.get()

  while true:
    await sleepAsync(WakuArchiveDefaultRetentionPolicyInterval)

    (await policy.execute(self.driver)).isOkOr:
      waku_archive_errors.inc(labelValues = [retPolicyFailure])
      error "failed execution of retention policy", error=error

proc periodicMetricReport(self: WakuArchive) {.async.} =
  while true:
    await sleepAsync(WakuArchiveDefaultMetricsReportInterval)

    let count = (await self.driver.getMessagesCount()).valueOr:
      error "loopReportStoredMessagesMetric failed to get messages count", error=error
      continue

    waku_archive_messages.set(count, labelValues = ["stored"])

proc start*(self: WakuArchive) =
  if self.retentionPolicy.isSome():
    self.retentionPolicyHandle = periodicRetentionPolicy(self)

  self.metricsHandle = periodicMetricReport(self)

proc stopWait*(self: WakuArchive) {.async.} =
  var futures: seq[Future[void]]

  if self.retentionPolicy.isSome() and not self.retentionPolicyHandle.isNil():
    futures.add(self.retentionPolicyHandle.cancelAndWait())

  if not self.metricsHandle.isNil:
    futures.add(self.metricsHandle.cancelAndWait())

  await noCancel(allFutures(futures))