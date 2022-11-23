when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/[tables, times, sequtils, options],
  stew/results,
  chronicles,
  chronos,
  metrics
import
  ../../utils/time,
  ../waku_message,
  ./common,
  ./archive_metrics,
  ./retention_policy,
  ./driver


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
          validator = none(MessageValidator),
          retentionPolicy = none(RetentionPolicy)): T =
  WakuArchive(
    driver: driver,
    validator: validator.get(nil),
    retentionPolicy: retentionPolicy.get(nil)
  )



proc handleMessage*(w: WakuArchive, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if msg.ephemeral:
    # Ephemeral message, do not store
    return

  if not w.validator.isNil():
    let validationRes = w.validator.validate(msg)
    if validationRes.isErr():
      waku_archive_errors.inc(labelValues = [invalidMessage])
      return


  waku_archive_insert_duration_seconds.time:
    let
      msgDigest = computeDigest(msg)
      msgReceivedTime = if msg.timestamp > 0: msg.timestamp
                        else: getNanosecondTime(getTime().toUnixFloat())

    trace "handling message", pubsubTopic=pubsubTopic, contentTopic=msg.contentTopic, timestamp=msg.timestamp, digest=msgDigest

    let putRes = w.driver.put(pubsubTopic, msg, msgDigest, msgReceivedTime)
    if putRes.isErr():
      error "failed to insert message", err=putRes.error
      waku_archive_errors.inc(labelValues = [insertFailure])


proc findMessages*(w: WakuArchive, query: ArchiveQuery): ArchiveResult {.gcsafe.} =
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


  var queryRes: ArchiveDriverResult[seq[ArchiveRow]]

  waku_archive_query_duration_seconds.time:
    queryRes = w.driver.getMessages(
      contentTopic = qContentTopics,
      pubsubTopic = qPubSubTopic,
      cursor = qCursor,
      startTime = qStartTime,
      endTime = qEndTime,
      maxPageSize = qMaxPageSize + 1,
      ascendingOrder = qAscendingOrder
    )

  # Build response
  if queryRes.isErr():
    return err(ArchiveError(kind: ArchiveErrorKind.DRIVER_ERROR, cause: queryRes.error))

  let rows = queryRes.get()

  if rows.len <= 0:
    return ok(ArchiveResponse(
      messages: @[],
      cursor: none(ArchiveCursor)
    ))


  # TODO: Move cursor generation to the driver implementation module
  var messages = if rows.len <= int(qMaxPageSize): rows.mapIt(it[1])
                 else: rows[0..^2].mapIt(it[1])
  var cursor = none(ArchiveCursor)

  if rows.len > int(qMaxPageSize):
    ## Build last message cursor
    ## The cursor is built from the last message INCLUDED in the response
    ## (i.e. the second last message in the rows list)
    let (pubsubTopic, message, digest, storeTimestamp) = rows[^2]

    # TODO: Improve coherence of MessageDigest type
    var messageDigest: array[32, byte]
    for i in 0..<min(digest.len, 32):
      messageDigest[i] = digest[i]

    cursor = some(ArchiveCursor(
      pubsubTopic: pubsubTopic,
      senderTime: message.timestamp,
      storeTime: storeTimestamp,
      digest: MessageDigest(data: messageDigest)
    ))


  ok(ArchiveResponse(
    messages: messages,
    cursor: cursor
  ))


# Retention policy

proc executeMessageRetentionPolicy*(w: WakuArchive) =
  if w.retentionPolicy.isNil():
    return

  if w.driver.isNil():
    return

  let retPolicyRes = w.retentionPolicy.execute(w.driver)
  if retPolicyRes.isErr():
      waku_archive_errors.inc(labelValues = [retPolicyFailure])
      error "failed execution of retention policy", error=retPolicyRes.error

proc reportStoredMessagesMetric*(w: WakuArchive) =
  if w.driver.isNil():
    return

  let resCount = w.driver.getMessagesCount()
  if resCount.isErr():
    error "failed to get messages count", error=resCount.error
    return

  waku_archive_messages.set(resCount.value, labelValues = ["stored"])
