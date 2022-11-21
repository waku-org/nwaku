## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables, times, sequtils, options, algorithm],
  stew/results,
  chronicles,
  chronos,
  bearssl/rand,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  metrics
import
  ../../node/message_store/message_retention_policy,
  ../../node/peer_manager/peer_manager,
  ../../utils/time,
  ../waku_message,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./message_store,
  ./protocol_metrics


logScope:
  topics = "waku store"


const
  MaxMessageTimestampVariance* = getNanoSecondTime(20) # 20 seconds maximum allowable sender timestamp "drift"


type
  WakuStore* = ref object of LPProtocol
    peerManager*: PeerManager
    rng*: ref rand.HmacDrbgContext
    store*: MessageStore
    retentionPolicy: Option[MessageRetentionPolicy]


# TODO: Move to a message store wrapper
proc executeMessageRetentionPolicy*(w: WakuStore) =
  if w.retentionPolicy.isNone():
    return

  if w.store.isNil():
    return

  let policy = w.retentionPolicy.get()

  let retPolicyRes = policy.execute(w.store)
  if retPolicyRes.isErr():
      waku_store_errors.inc(labelValues = [retPolicyFailure])
      debug "failed execution of retention policy", error=retPolicyRes.error

# TODO: Move to a message store wrapper
proc reportStoredMessagesMetric*(w: WakuStore) =
  if w.store.isNil():
    return

  let resCount = w.store.getMessagesCount()
  if resCount.isErr():
    return

  waku_store_messages.set(resCount.value, labelValues = ["stored"])

# TODO: Move to a message store wrapper
proc isValidMessage(msg: WakuMessage): bool =
  if msg.timestamp == 0:
    return true

  let
    now = getNanosecondTime(getTime().toUnixFloat())
    lowerBound = now - MaxMessageTimestampVariance
    upperBound = now + MaxMessageTimestampVariance

  return lowerBound <= msg.timestamp and msg.timestamp <= upperBound

# TODO: Move to a message store wrapper
proc handleMessage*(w: WakuStore, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  if w.store.isNil():
    # Messages should not be stored
    return

  if msg.ephemeral:
    # The message is ephemeral, should not be stored
    return

  if not isValidMessage(msg):
    waku_store_errors.inc(labelValues = [invalidMessage])
    return


  let insertStartTime = getTime().toUnixFloat()

  block:
    let
      msgDigest = computeDigest(msg)
      msgReceivedTime = if msg.timestamp > 0: msg.timestamp
                        else: getNanosecondTime(getTime().toUnixFloat())

    trace "handling message", pubsubTopic=pubsubTopic, contentTopic=msg.contentTopic, timestamp=msg.timestamp, digest=msgDigest

    let putStoreRes = w.store.put(pubsubTopic, msg, msgDigest, msgReceivedTime)
    if putStoreRes.isErr():
      debug "failed to insert message into the store", err=putStoreRes.error
      waku_store_errors.inc(labelValues = [insertFailure])
      return

  let insertDuration = getTime().toUnixFloat() - insertStartTime
  waku_store_insert_duration_seconds.observe(insertDuration)


# TODO: Move to a message store wrapper
proc findMessages(w: WakuStore, query: HistoryQuery): HistoryResult {.gcsafe.} =
  ## Query history to return a single page of messages matching the query

  # Extract query criteria. All query criteria are optional
  let
    qContentTopics = if query.contentTopics.len == 0: none(seq[ContentTopic])
                     else: some(query.contentTopics)
    qPubSubTopic = query.pubsubTopic
    qCursor = query.cursor
    qStartTime = query.startTime
    qEndTime = query.endTime
    qMaxPageSize = if query.pageSize <= 0: DefaultPageSize
                   else: min(query.pageSize, MaxPageSize)
    qAscendingOrder = query.ascending


  let queryStartTime = getTime().toUnixFloat()

  let queryRes = w.store.getMessagesByHistoryQuery(
        contentTopic = qContentTopics,
        pubsubTopic = qPubSubTopic,
        cursor = qCursor,
        startTime = qStartTime,
        endTime = qEndTime,
        maxPageSize = qMaxPageSize + 1,
        ascendingOrder = qAscendingOrder
      )

  let queryDuration = getTime().toUnixFloat() - queryStartTime
  waku_store_query_duration_seconds.observe(queryDuration)


  # Build response
  if queryRes.isErr():
    # TODO: Improve error reporting
    return err(HistoryError(kind: HistoryErrorKind.UNKNOWN))

  let rows = queryRes.get()

  if rows.len <= 0:
    return ok(HistoryResponse(
      messages: @[],
      pageSize: 0,
      ascending: qAscendingOrder,
      cursor: none(HistoryCursor)
    ))


  var messages = if rows.len <= int(qMaxPageSize): rows.mapIt(it[1])
                 else: rows[0..^2].mapIt(it[1])
  var cursor = none(HistoryCursor)

  # The retrieved messages list should always be in chronological order
  if not qAscendingOrder:
    messages.reverse()


  if rows.len > int(qMaxPageSize):
    ## Build last message cursor
    ## The cursor is built from the last message INCLUDED in the response
    ## (i.e. the second last message in the rows list)
    let (pubsubTopic, message, digest, storeTimestamp) = rows[^2]

    # TODO: Improve coherence of MessageDigest type
    var messageDigest: array[32, byte]
    for i in 0..<min(digest.len, 32):
      messageDigest[i] = digest[i]

    cursor = some(HistoryCursor(
      pubsubTopic: pubsubTopic,
      senderTime: message.timestamp,
      storeTime: storeTimestamp,
      digest: MessageDigest(data: messageDigest)
    ))


  ok(HistoryResponse(
    messages: messages,
    pageSize: uint64(messages.len),
    ascending: qAscendingOrder,
    cursor: cursor
  ))


## Protocol

proc initProtocolHandler(ws: WakuStore) =

  proc handler(conn: Connection, proto: string) {.async.} =
    let buf = await conn.readLp(MaxRpcSize.int)

    let decodeRes = HistoryRPC.decode(buf)
    if decodeRes.isErr():
      error "failed to decode rpc", peerId=conn.peerId
      waku_store_errors.inc(labelValues = [decodeRpcFailure])
      # TODO: Return (BAD_REQUEST, cause: "decode rpc failed")
      return


    let reqRpc = decodeRes.value

    if reqRpc.query.isNone():
      error "empty query rpc", peerId=conn.peerId, requestId=reqRpc.requestId
      waku_store_errors.inc(labelValues = [emptyRpcQueryFailure])
      # TODO: Return (BAD_REQUEST, cause: "empty query")
      return


    info "received history query", peerId=conn.peerId, requestId=reqRpc.requestId, query=reqRpc.query
    waku_store_queries.inc()


    if ws.store.isNil():
      let respErr = HistoryError(kind: HistoryErrorKind.SERVICE_UNAVAILABLE)

      error "history query failed", peerId=conn.peerId, requestId=reqRpc.requestId, error= $respErr

      let resp = HistoryResponseRPC(error: respErr.toRPC())
      let rpc = HistoryRPC(requestId: reqRpc.requestId, response: some(resp))
      await conn.writeLp(rpc.encode().buffer)
      return


    let query = reqRpc.query.get().toAPI()

    let respRes = ws.findMessages(query)

    if respRes.isErr():
      error "history query failed", peerId=conn.peerId, requestId=reqRpc.requestId, error=respRes.error

      let resp = respRes.toRPC()
      let rpc = HistoryRPC(requestId: reqRpc.requestId, response: some(resp))
      await conn.writeLp(rpc.encode().buffer)
      return


    let resp = respRes.toRPC()

    info "sending history response", peerId=conn.peerId, requestId=reqRpc.requestId, messages=resp.messages.len

    let rpc = HistoryRPC(requestId: reqRpc.requestId, response: some(resp))
    await conn.writeLp(rpc.encode().buffer)

  ws.handler = handler
  ws.codec = WakuStoreCodec

proc new*(T: type WakuStore,
           peerManager: PeerManager,
           rng: ref rand.HmacDrbgContext,
           store: MessageStore,
           retentionPolicy=none(MessageRetentionPolicy)): T =
  let ws = WakuStore(
    rng: rng,
    peerManager: peerManager,
    store: store,
    retentionPolicy: retentionPolicy
  )
  ws.initProtocolHandler()
  ws
