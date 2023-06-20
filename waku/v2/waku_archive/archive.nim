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
  ../../common/databases/dburl,
  ../../common/databases/db_sqlite,
  ./driver_base,
  ./driver/queue_driver,
  ./driver/sqlite_driver,
  ./driver/sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ./driver/postgres_driver/postgres_driver,
  ./retention_policy,
  ./retention_policy/retention_policy_capacity,
  ./retention_policy/retention_policy_time,
  ../waku_core,
  ./common,
  ./archive_metrics,
  ./retention_policy as ret_policy

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

# these are defined few lines below. Just declaring to use them in 'new'.
proc setupWakuArchiveDriver(url: string, vacuum: bool, migrate: bool):
                            Result[ArchiveDriver, string]
proc validateStoreMessageRetentionPolicy(val: string):
                                         Result[string, string]
proc setupWakuArchiveRetentionPolicy(retentionPolicy: string):
                                     Result[RetentionPolicy, string]

proc new*(T: type WakuArchive,
          storeMessageDbUrl: string,
          storeMessageDbVacuum: bool = false,
          storeMessageDbMigration: bool = false,
          storeMessageRetentionPolicy: string = "none"):
          Result[T, string] =

  # Message storage
  let dbUrlValidationRes = dburl.validateDbUrl(storeMessageDbUrl)
  if dbUrlValidationRes.isErr():
    return err("failed to configure the message store database connection: " &
               dbUrlValidationRes.error)

  let archiveDriverRes =
                     setupWakuArchiveDriver(dbUrlValidationRes.get(),
                                            vacuum = storeMessageDbVacuum,
                                            migrate = storeMessageDbMigration)
  if archiveDriverRes.isErr():
    return err("failed to configure archive driver: " & archiveDriverRes.error)

  let archiveDriver = archiveDriverRes.get()

  # Message store retention policy
  let storeMessageRetentionPolicyRes =
            validateStoreMessageRetentionPolicy(storeMessageRetentionPolicy)

  if storeMessageRetentionPolicyRes.isErr():
    return err("failed to configure the message retention policy: " &
               storeMessageRetentionPolicyRes.error)

  let archiveRetentionPolicyRes =
          setupWakuArchiveRetentionPolicy(storeMessageRetentionPolicyRes.get())

  if archiveRetentionPolicyRes.isErr():
    return err("failed to configure the message retention policy: " &
               archiveRetentionPolicyRes.error)

  let retentionPolicy = archiveRetentionPolicyRes.get()

  let wakuArch = WakuArchive(driver: archiveDriver,
                             validator: DefaultMessageValidator(),
                             retentionPolicy: retentionPolicy)
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
      msgReceivedTime = if msg.timestamp > 0: msg.timestamp
                        else: getNanosecondTime(getTime().toUnixFloat())

    trace "handling message", pubsubTopic=pubsubTopic, contentTopic=msg.contentTopic, timestamp=msg.timestamp, digest=msgDigest

    let putRes = await w.driver.put(pubsubTopic, msg, msgDigest, msgReceivedTime)
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

  var executeRetentionPolicy: proc(udata: pointer) {.gcsafe, raises: [Defect].}
  executeRetentionPolicy = proc(udata: pointer) {.gcsafe.} =

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

  discard setTimer(Moment.fromNow(interval), executeRetentionPolicy)

proc setupWakuArchiveDriver(url: string, vacuum: bool, migrate: bool):
                            Result[ArchiveDriver, string] =

  let engineRes = dburl.getDbEngine(url)
  if engineRes.isErr():
    return err("error getting db engine in setupWakuArchiveDriver: " &
               engineRes.error)

  let engine = engineRes.get()

  case engine
  of "sqlite":
    let pathRes = dburl.getDbPath(url)
    if pathRes.isErr():
      return err("error get path in setupWakuArchiveDriver: " & pathRes.error)

    let dbRes = SqliteDatabase.new(pathRes.get())
    if dbRes.isErr():
      return err("error in setupWakuArchiveDriver: " & dbRes.error)

    let db = dbRes.get()

    # SQLite vacuum
    let (pageSize, pageCount, freelistCount) = ? db.gatherSqlitePageStats()
    debug "sqlite database page stats", pageSize = pageSize,
                                        pages = pageCount,
                                        freePages = freelistCount

    if vacuum and (pageCount > 0 and freelistCount > 0):
      ? db.performSqliteVacuum()

    # Database migration
    if migrate:
      ? archive_driver_sqlite_migrations.migrate(db)

    debug "setting up sqlite waku archive driver"
    let res = SqliteDriver.new(db)
    if res.isErr():
      return err("failed to init sqlite archive driver: " & res.error)

    return ok(res.get())

  else:
    debug "setting up in-memory waku archive driver"
    let driver = QueueDriver.new()  # Defaults to a capacity of 25.000 messages
    return ok(driver)

proc validateStoreMessageRetentionPolicy(val: string):
                                         Result[string, string] =
  const StoreMessageRetentionPolicyRegex = re"^\w+:\w+$"
  if val == "" or val == "none" or val.match(StoreMessageRetentionPolicyRegex):
    ok(val)
  else:
    err("invalid 'store message retention policy' option format: " & val)

proc setupWakuArchiveRetentionPolicy(retentionPolicy: string):
                                     Result[RetentionPolicy, string] =
  if retentionPolicy == "" or retentionPolicy == "none":
    return ok(RetentionPolicy())

  let rententionPolicyParts = retentionPolicy.split(":", 1)
  let
    policy = rententionPolicyParts[0]
    policyArgs = rententionPolicyParts[1]

  if policy == "time":
    var retentionTimeSeconds: int64
    try:
      retentionTimeSeconds = parseInt(policyArgs)
    except ValueError:
      return err("invalid time retention policy argument")

    let retPolicy: RetentionPolicy = TimeRetentionPolicy.init(retentionTimeSeconds)
    return ok(retPolicy)

  elif policy == "capacity":
    var retentionCapacity: int
    try:
      retentionCapacity = parseInt(policyArgs)
    except ValueError:
      return err("invalid capacity retention policy argument")

    let retPolicy: RetentionPolicy = CapacityRetentionPolicy.init(retentionCapacity)
    return ok(retPolicy)

  else:
    return err("unknown retention policy")
