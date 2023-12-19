when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables, times, sequtils, options, algorithm, strutils],
  stew/results,
  chronicles,
  chronos,
  regex,
  metrics
import
  ../common/[
    databases/dburl,
    databases/db_sqlite,
    paging
  ],
  ./driver,
  ./retention_policy,
  ./retention_policy/retention_policy_capacity,
  ./retention_policy/retention_policy_time,
  ../waku_core,
  ../waku_core/message/digest,
  ./common,
  ./archive_metrics

logScope:
  topics = "waku archive"

const
  DefaultPageSize*: uint = 20
  MaxPageSize*: uint = 100

## Message validation

type
  MessageValidator* = ref object of RootObj

  ValidationResult* = Result[void, string]

method validate*(validator: MessageValidator, msg: WakuMessage): ValidationResult {.base.} = discard

# Default message validator

const MaxMessageTimestampVariance* = getNanoSecondTime(20) # 20 seconds maximum allowable sender timestamp "drift"

type DefaultMessageValidator* = ref object of MessageValidator

method validate*(validator: DefaultMessageValidator, msg: WakuMessage): ValidationResult =
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

  ok()

## Archive

type
  WakuArchive* = ref object
    driver*: ArchiveDriver  # TODO: Make this field private. Remove asterisk
    validator: MessageValidator
    retentionPolicy: RetentionPolicy
    retPolicyFut: Future[Result[void, string]]  ## retention policy cancelable future
    retMetricsRepFut: Future[Result[void, string]]  ## metrics reporting cancelable future

proc new*(T: type WakuArchive,
          driver: ArchiveDriver,
          retentionPolicy = none(RetentionPolicy)):
          Result[T, string] =

  let retPolicy = if retentionPolicy.isSome():
                    retentionPolicy.get()
                  else:
                    nil

  let wakuArch = WakuArchive(driver: driver,
                             validator: DefaultMessageValidator(),
                             retentionPolicy: retPolicy)
  return ok(wakuArch)

proc handleMessage*(w: WakuArchive,
                    pubsubTopic: PubsubTopic,
                    msg: WakuMessage) {.async.} =
  if msg.ephemeral:
    # Ephemeral message, do not store
    return

  if not w.validator.isNil():
    let validationRes = w.validator.validate(msg)
    if validationRes.isErr():
      waku_archive_errors.inc(labelValues = [validationRes.error])
      return

  let insertStartTime = getTime().toUnixFloat()

  block:
    let
      msgDigest = computeDigest(msg)
      msgHash = computeMessageHash(pubsubTopic, msg)
      msgReceivedTime = if msg.timestamp > 0: msg.timestamp
                        else: getNanosecondTime(getTime().toUnixFloat())

    trace "handling message", pubsubTopic=pubsubTopic, contentTopic=msg.contentTopic, timestamp=msg.timestamp, digest=msgDigest, messageHash=msgHash

    let putRes = await w.driver.put(pubsubTopic, msg, msgDigest, msgHash, msgReceivedTime)
    if putRes.isErr():
      if "duplicate key value violates unique constraint" in putRes.error:
        trace "failed to insert message", err=putRes.error
      else:
        debug "failed to insert message", err=putRes.error
      waku_archive_errors.inc(labelValues = [insertFailure])

  let insertDuration = getTime().toUnixFloat() - insertStartTime
  waku_archive_insert_duration_seconds.observe(insertDuration)

proc findMessages*(w: WakuArchive, query: ArchiveQuery): Future[ArchiveResult] {.async, gcsafe.} =
  ## Search the archive to return a single page of messages matching the query criteria
  let
    qContentTopics = query.contentTopics
    qPubSubTopic = query.pubsubTopic
    qCursor = query.cursor
    qStartTime = query.startTime
    qEndTime = query.endTime
    qMaxPageSize = if query.pageSize <= 0: DefaultPageSize
                   else: min(query.pageSize, MaxPageSize)
    isAscendingOrder = query.direction.into()

  if qContentTopics.len > 10:
    return err(ArchiveError.invalidQuery("too many content topics"))

  let queryStartTime = getTime().toUnixFloat()

  let queryRes = await w.driver.getMessages(
      contentTopic = qContentTopics,
      pubsubTopic = qPubSubTopic,
      cursor = qCursor,
      startTime = qStartTime,
      endTime = qEndTime,
      maxPageSize = qMaxPageSize + 1,
      ascendingOrder = isAscendingOrder
    )

  let queryDuration = getTime().toUnixFloat() - queryStartTime
  waku_archive_query_duration_seconds.observe(queryDuration)

  # Build response
  if queryRes.isErr():
    return err(ArchiveError(kind: ArchiveErrorKind.DRIVER_ERROR, cause: queryRes.error))

  let rows = queryRes.get()
  var messages = newSeq[WakuMessage]()
  var cursor = none(ArchiveCursor)
  if rows.len == 0:
    return ok(ArchiveResponse(messages: messages, cursor: cursor))

  ## Messages
  let pageSize = min(rows.len, int(qMaxPageSize))
  messages = rows[0..<pageSize].mapIt(it[1])

  ## Cursor
  if rows.len > int(qMaxPageSize):
    ## Build last message cursor
    ## The cursor is built from the last message INCLUDED in the response
    ## (i.e. the second last message in the rows list)
    let (pubsubTopic, message, digest, storeTimestamp) = rows[^2]

    # TODO: Improve coherence of MessageDigest type
    let messageDigest = block:
        var data: array[32, byte]
        for i in 0..<min(digest.len, 32):
          data[i] = digest[i]

        MessageDigest(data: data)

    cursor = some(ArchiveCursor(
      pubsubTopic: pubsubTopic,
      senderTime: message.timestamp,
      storeTime: storeTimestamp,
      digest: messageDigest
    ))

  # All messages MUST be returned in chronological order
  if not isAscendingOrder:
    reverse(messages)

  return ok(ArchiveResponse(messages: messages, cursor: cursor))

# Retention policy
const WakuArchiveDefaultRetentionPolicyInterval* = chronos.minutes(30)

proc loopApplyRetentionPolicy*(w: WakuArchive):
                               Future[Result[void, string]] {.async.} =

  if w.retentionPolicy.isNil():
    return err("retentionPolicy is Nil in executeMessageRetentionPolicy")

  if w.driver.isNil():
    return err("driver is Nil in executeMessageRetentionPolicy")

  while true:
    debug "executing message retention policy"
    let retPolicyRes = await w.retentionPolicy.execute(w.driver)
    if retPolicyRes.isErr():
        waku_archive_errors.inc(labelValues = [retPolicyFailure])
        error "failed execution of retention policy", error=retPolicyRes.error

    await sleepAsync(WakuArchiveDefaultRetentionPolicyInterval)

  return ok()

# Metrics reporting
const WakuArchiveDefaultMetricsReportInterval* = chronos.minutes(1)

proc loopReportStoredMessagesMetric*(w: WakuArchive):
                                     Future[Result[void, string]] {.async.} =
  if w.driver.isNil():
    return err("driver is Nil in loopReportStoredMessagesMetric")

  while true:
    let resCount = await w.driver.getMessagesCount()
    if resCount.isErr():
      return err("loopReportStoredMessagesMetric failed to get messages count: " & resCount.error)

    waku_archive_messages.set(resCount.value, labelValues = ["stored"])
    await sleepAsync(WakuArchiveDefaultMetricsReportInterval)

  return ok()

proc start*(self: WakuArchive) {.async.} =
  ## TODO: better control the Result in case of error. Now it is ignored
  self.retPolicyFut = self.loopApplyRetentionPolicy()
  self.retMetricsRepFut = self.loopReportStoredMessagesMetric()

proc stop*(self: WakuArchive) {.async.} =
  self.retPolicyFut.cancel()
  self.retMetricsRepFut.cancel()
