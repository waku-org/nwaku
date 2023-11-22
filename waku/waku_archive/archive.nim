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
  ../common/databases/dburl,
  ../common/databases/db_sqlite,
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
      error "failed to insert message", err=putRes.error
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
    qAscendingOrder = query.ascending

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
      ascendingOrder = qAscendingOrder
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
  if not qAscendingOrder:
    reverse(messages)

  return ok(ArchiveResponse(messages: messages, cursor: cursor))

# Retention policy

proc executeMessageRetentionPolicy*(w: WakuArchive):
                                    Future[Result[void, string]] {.async.} =
  if w.retentionPolicy.isNil():
    return err("retentionPolicy is Nil in executeMessageRetentionPolicy")

  if w.driver.isNil():
    return err("driver is Nil in executeMessageRetentionPolicy")

  let retPolicyRes = await w.retentionPolicy.execute(w.driver)
  if retPolicyRes.isErr():
      waku_archive_errors.inc(labelValues = [retPolicyFailure])
      return err("failed execution of retention policy: " & retPolicyRes.error)

  return ok()

proc reportStoredMessagesMetric*(w: WakuArchive):
                                 Future[Result[void, string]] {.async.} =
  if w.driver.isNil():
    return err("driver is Nil in reportStoredMessagesMetric")

  let resCount = await w.driver.getMessagesCount()
  if resCount.isErr():
    return err("failed to get messages count: " & resCount.error)

  waku_archive_messages.set(resCount.value, labelValues = ["stored"])

  return ok()

proc startMessageRetentionPolicyPeriodicTask*(w: WakuArchive,
                                              interval: timer.Duration) =
  # Start the periodic message retention policy task
  # https://github.com/nim-lang/Nim/issues/17369

  var executeRetentionPolicy: CallbackFunc
  executeRetentionPolicy =
    CallbackFunc(
      proc (arg: pointer) {.gcsafe, raises: [].} =
        try:
          let retPolRes = waitFor w.executeMessageRetentionPolicy()
          if retPolRes.isErr():
            waku_archive_errors.inc(labelValues = [retPolicyFailure])
            error "error in periodic retention policy", error = retPolRes.error
        except CatchableError:
          waku_archive_errors.inc(labelValues = [retPolicyFailure])
          error "exception in periodic retention policy",
                error = getCurrentExceptionMsg()

        discard setTimer(Moment.fromNow(interval), executeRetentionPolicy)
    )

  discard setTimer(Moment.fromNow(interval), executeRetentionPolicy)
