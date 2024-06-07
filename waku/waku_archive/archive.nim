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
  DefaultPageSize*: uint = 20
  MaxPageSize*: uint = 100

  # Retention policy
  WakuArchiveDefaultRetentionPolicyInterval* = chronos.minutes(30)

  # Metrics reporting
  WakuArchiveDefaultMetricsReportInterval* = chronos.minutes(30)

  # Message validation
  # 20 seconds maximum allowable sender timestamp "drift"
  MaxMessageTimestampVariance* = getNanoSecondTime(20)

type MessageValidator* =
  proc(msg: WakuMessage): Result[void, string] {.closure, gcsafe, raises: [].}

## Archive

type WakuArchive* = ref object
  driver: ArchiveDriver

  validator: MessageValidator

  retentionPolicy: Option[RetentionPolicy]

  retentionPolicyHandle: Future[void]
  metricsHandle: Future[void]

proc validate*(msg: WakuMessage): Result[void, string] =
  if msg.ephemeral:
    # Ephemeral message, do not store
    return

  if msg.timestamp == 0:
    return ok()

  let
    now = getNanosecondTime(getTime().toUnixFloat())
    lowerBound = now - MaxMessageTimestampVariance
    upperBound = now + MaxMessageTimestampVariance

  if msg.timestamp < lowerBound:
    return err(invalidMessageOld)

  if upperBound < msg.timestamp:
    return err(invalidMessageFuture)

  return ok()

proc new*(
    T: type WakuArchive,
    driver: ArchiveDriver,
    validator: MessageValidator = validate,
    retentionPolicy = none(RetentionPolicy),
): Result[T, string] =
  if driver.isNil():
    return err("archive driver is Nil")

  let archive =
    WakuArchive(driver: driver, validator: validator, retentionPolicy: retentionPolicy)

  return ok(archive)

proc handleMessage*(
    self: WakuArchive, pubsubTopic: PubsubTopic, msg: WakuMessage
) {.async.} =
  self.validator(msg).isOkOr:
    waku_archive_errors.inc(labelValues = [error])
    return

  let
    msgDigest = computeDigest(msg)
    msgDigestHex = msgDigest.data.to0xHex()
    msgHash = computeMessageHash(pubsubTopic, msg)
    msgHashHex = msgHash.to0xHex()
    msgTimestamp =
      if msg.timestamp > 0:
        msg.timestamp
      else:
        getNanosecondTime(getTime().toUnixFloat())

  trace "handling message",
    msg_hash = msgHashHex,
    pubsubTopic = pubsubTopic,
    contentTopic = msg.contentTopic,
    msgTimestamp = msg.timestamp,
    usedTimestamp = msgTimestamp,
    digest = msgDigestHex

  let insertStartTime = getTime().toUnixFloat()

  (await self.driver.put(pubsubTopic, msg, msgDigest, msgHash, msgTimestamp)).isOkOr:
    waku_archive_errors.inc(labelValues = [insertFailure])
    error "failed to insert message", error = error

  debug "message archived",
    msg_hash = msgHashHex,
    pubsubTopic = pubsubTopic,
    contentTopic = msg.contentTopic,
    msgTimestamp = msg.timestamp,
    usedTimestamp = msgTimestamp,
    digest = msgDigestHex

  let insertDuration = getTime().toUnixFloat() - insertStartTime
  waku_archive_insert_duration_seconds.observe(insertDuration)

proc findMessages*(
    self: WakuArchive, query: ArchiveQuery
): Future[ArchiveResult] {.async, gcsafe.} =
  ## Search the archive to return a single page of messages matching the query criteria

  let maxPageSize =
    if query.pageSize <= 0:
      DefaultPageSize
    else:
      min(query.pageSize, MaxPageSize)

  let isAscendingOrder = query.direction.into()

  if query.contentTopics.len > 10:
    return err(ArchiveError.invalidQuery("too many content topics"))

  if query.cursor.isSome() and query.cursor.get().hash.len != 32:
    return err(ArchiveError.invalidQuery("invalid cursor hash length"))

  let queryStartTime = getTime().toUnixFloat()

  let rows = (
    await self.driver.getMessages(
      includeData = query.includeData,
      contentTopic = query.contentTopics,
      pubsubTopic = query.pubsubTopic,
      cursor = query.cursor,
      startTime = query.startTime,
      endTime = query.endTime,
      hashes = query.hashes,
      maxPageSize = maxPageSize + 1,
      ascendingOrder = isAscendingOrder,
    )
  ).valueOr:
    return err(ArchiveError(kind: ArchiveErrorKind.DRIVER_ERROR, cause: error))

  let queryDuration = getTime().toUnixFloat() - queryStartTime
  waku_archive_query_duration_seconds.observe(queryDuration)

  var hashes = newSeq[WakuMessageHash]()
  var messages = newSeq[WakuMessage]()
  var topics = newSeq[PubsubTopic]()
  var cursor = none(ArchiveCursor)

  if rows.len == 0:
    return ok(ArchiveResponse(hashes: hashes, messages: messages, cursor: cursor))

  ## Messages
  let pageSize = min(rows.len, int(maxPageSize))

  #TODO once store v2 is removed, unzip instead of 2x map
  #TODO once store v2 is removed, update driver to not return messages when not needed
  if query.includeData:
    topics = rows[0 ..< pageSize].mapIt(it[0])
    messages = rows[0 ..< pageSize].mapIt(it[1])

  hashes = rows[0 ..< pageSize].mapIt(it[4])

  ## Cursor
  if rows.len > int(maxPageSize):
    ## Build last message cursor
    ## The cursor is built from the last message INCLUDED in the response
    ## (i.e. the second last message in the rows list)

    #TODO Once Store v2 is removed keep only message and hash
    let (pubsubTopic, message, digest, storeTimestamp, hash) = rows[^2]

    #TODO Once Store v2 is removed, the cursor becomes the hash of the last message
    cursor = some(
      ArchiveCursor(
        digest: MessageDigest.fromBytes(digest),
        storeTime: storeTimestamp,
        sendertime: message.timestamp,
        pubsubTopic: pubsubTopic,
        hash: hash,
      )
    )

  # All messages MUST be returned in chronological order
  if not isAscendingOrder:
    reverse(hashes)
    reverse(messages)
    reverse(topics)

  return ok(
    ArchiveResponse(hashes: hashes, messages: messages, topics: topics, cursor: cursor)
  )

proc findMessagesV2*(
    self: WakuArchive, query: ArchiveQuery
): Future[ArchiveResult] {.async, deprecated, gcsafe.} =
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

  let rows = (
    await self.driver.getMessagesV2(
      contentTopic = query.contentTopics,
      pubsubTopic = query.pubsubTopic,
      cursor = query.cursor,
      startTime = query.startTime,
      endTime = query.endTime,
      maxPageSize = maxPageSize + 1,
      ascendingOrder = isAscendingOrder,
    )
  ).valueOr:
    return err(ArchiveError(kind: ArchiveErrorKind.DRIVER_ERROR, cause: error))

  let queryDuration = getTime().toUnixFloat() - queryStartTime
  waku_archive_query_duration_seconds.observe(queryDuration)

  var messages = newSeq[WakuMessage]()
  var cursor = none(ArchiveCursor)

  if rows.len == 0:
    return ok(ArchiveResponse(messages: messages, cursor: cursor))

  ## Messages
  let pageSize = min(rows.len, int(maxPageSize))

  messages = rows[0 ..< pageSize].mapIt(it[1])

  ## Cursor
  if rows.len > int(maxPageSize):
    ## Build last message cursor
    ## The cursor is built from the last message INCLUDED in the response
    ## (i.e. the second last message in the rows list)

    let (pubsubTopic, message, digest, storeTimestamp, _) = rows[^2]

    cursor = some(
      ArchiveCursor(
        digest: MessageDigest.fromBytes(digest),
        storeTime: storeTimestamp,
        sendertime: message.timestamp,
        pubsubTopic: pubsubTopic,
      )
    )

  # All messages MUST be returned in chronological order
  if not isAscendingOrder:
    reverse(messages)

  return ok(ArchiveResponse(messages: messages, cursor: cursor))

proc periodicRetentionPolicy(self: WakuArchive) {.async.} =
  debug "executing message retention policy"

  let policy = self.retentionPolicy.get()

  while true:
    (await policy.execute(self.driver)).isOkOr:
      waku_archive_errors.inc(labelValues = [retPolicyFailure])
      error "failed execution of retention policy", error = error

    await sleepAsync(WakuArchiveDefaultRetentionPolicyInterval)

proc periodicMetricReport(self: WakuArchive) {.async.} =
  while true:
    let countRes = (await self.driver.getMessagesCount())
    if countRes.isErr():
      error "loopReportStoredMessagesMetric failed to get messages count",
        error = countRes.error
    else:
      let count = countRes.get()
      waku_archive_messages.set(count, labelValues = ["stored"])

    await sleepAsync(WakuArchiveDefaultMetricsReportInterval)

proc start*(self: WakuArchive) =
  if self.retentionPolicy.isSome():
    self.retentionPolicyHandle = self.periodicRetentionPolicy()

  self.metricsHandle = self.periodicMetricReport()

proc stopWait*(self: WakuArchive) {.async.} =
  var futures: seq[Future[void]]

  if self.retentionPolicy.isSome() and not self.retentionPolicyHandle.isNil():
    futures.add(self.retentionPolicyHandle.cancelAndWait())

  if not self.metricsHandle.isNil:
    futures.add(self.metricsHandle.cancelAndWait())

  await noCancel(allFutures(futures))
