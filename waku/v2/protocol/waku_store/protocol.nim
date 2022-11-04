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
  ../../node/message_store/waku_store_queue,
  ../../node/peer_manager/peer_manager,
  ../../utils/time,
  ../waku_message,
  ../waku_swap/waku_swap,
  ./rpc,
  ./rpc_codec,
  ./pagination,
  ./message_store,
  ./protocol_metrics


logScope:
  topics = "waku store"


const 
  WakuStoreCodec* = "/vac/waku/store/2.0.0-beta4"

  DefaultTopic* = "/waku/2/default-waku/proto"

  MaxMessageTimestampVariance* = getNanoSecondTime(20) # 20 seconds maximum allowable sender timestamp "drift"


type
  WakuStoreResult*[T] = Result[T, string]

  WakuStore* = ref object of LPProtocol
    peerManager*: PeerManager
    rng*: ref rand.HmacDrbgContext
    store*: MessageStore
    wakuSwap*: WakuSwap
    retentionPolicy: Option[MessageRetentionPolicy]


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


proc reportStoredMessagesMetric*(w: WakuStore) = 
  if w.store.isNil():
    return

  let resCount = w.store.getMessagesCount()
  if resCount.isErr():
    return

  waku_store_messages.set(resCount.value, labelValues = ["stored"])


proc findMessages(w: WakuStore, query: HistoryQuery): HistoryResponse {.gcsafe.} =
  ## Query history to return a single page of messages matching the query
  
  # Extract query criteria. All query criteria are optional
  let
    qContentTopics = if (query.contentFilters.len != 0): some(query.contentFilters.mapIt(it.contentTopic))
                     else: none(seq[ContentTopic])
    qPubSubTopic = if (query.pubsubTopic != ""): some(query.pubsubTopic)
                   else: none(string)
    qCursor = if query.pagingInfo.cursor != PagingIndex(): some(query.pagingInfo.cursor)
              else: none(PagingIndex)
    qStartTime = if query.startTime != Timestamp(0): some(query.startTime)
                 else: none(Timestamp)
    qEndTime = if query.endTime != Timestamp(0): some(query.endTime)
               else: none(Timestamp)
    qMaxPageSize = if query.pagingInfo.pageSize <= 0: DefaultPageSize
                   else: min(query.pagingInfo.pageSize, MaxPageSize)
    qAscendingOrder = query.pagingInfo.direction == PagingDirection.FORWARD


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
  # TODO: Improve error reporting
  if queryRes.isErr():
    return HistoryResponse(messages: @[], pagingInfo: PagingInfo(), error: HistoryResponseError.INVALID_CURSOR)

  let rows = queryRes.get()
  
  if rows.len <= 0:
    return HistoryResponse(messages: @[], error: HistoryResponseError.NONE)
  
  var messages = if rows.len <= int(qMaxPageSize): rows.mapIt(it[1])
                 else: rows[0..^2].mapIt(it[1])
  var pagingInfo = none(PagingInfo)

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

    let pagingIndex = PagingIndex(
      pubsubTopic: pubsubTopic, 
      senderTime: message.timestamp,
      receiverTime: storeTimestamp,
      digest: MessageDigest(data: messageDigest)
    )

    pagingInfo = some(PagingInfo(
      pageSize: uint64(messages.len),
      cursor: pagingIndex,
      direction: if qAscendingOrder: PagingDirection.FORWARD
                else: PagingDirection.BACKWARD
    ))

  HistoryResponse(
    messages: messages, 
    pagingInfo: pagingInfo.get(PagingInfo()),
    error: HistoryResponseError.NONE
  )

proc initProtocolHandler*(ws: WakuStore) =
  
  proc handler(conn: Connection, proto: string) {.async.} =
    let buf = await conn.readLp(MaxRpcSize.int)

    let resReq = HistoryRPC.init(buf)
    if resReq.isErr():
      error "failed to decode rpc", peerId=conn.peerId
      waku_store_errors.inc(labelValues = [decodeRpcFailure])
      return

    let req = resReq.value

    info "received history query", peerId=conn.peerId, requestId=req.requestId, query=req.query
    waku_store_queries.inc()

    let resp = if not ws.store.isNil(): ws.findMessages(req.query)
               # TODO: Improve error reporting
               else: HistoryResponse(error: HistoryResponseError.SERVICE_UNAVAILABLE)

    if not ws.wakuSwap.isNil():
      info "handle store swap", peerId=conn.peerId, requestId=req.requestId, text=ws.wakuSwap.text

      # Perform accounting operation
      # TODO: Do accounting here, response is HistoryResponse. How do we get node or swap context?
      let peerId = conn.peerId
      let messages = resp.messages
      ws.wakuSwap.credit(peerId, messages.len)

    info "sending history response", peerId=conn.peerId, requestId=req.requestId, messages=resp.messages.len

    let rpc = HistoryRPC(requestId: req.requestId, response: resp)
    await conn.writeLp(rpc.encode().buffer)

  ws.handler = handler
  ws.codec = WakuStoreCodec

proc new*(T: type WakuStore, 
           peerManager: PeerManager, 
           rng: ref rand.HmacDrbgContext,
           store: MessageStore, 
           wakuSwap: WakuSwap = nil, 
           retentionPolicy=none(MessageRetentionPolicy)): T =
  let ws = WakuStore(
    rng: rng, 
    peerManager: peerManager, 
    store: store, 
    wakuSwap: wakuSwap, 
    retentionPolicy: retentionPolicy
  )
  ws.initProtocolHandler()

  return ws

proc init*(T: type WakuStore, 
           peerManager: PeerManager, 
           rng: ref rand.HmacDrbgContext,
           wakuSwap: WakuSwap = nil, 
           retentionPolicy=none(MessageRetentionPolicy)): T =
  let store = StoreQueueRef.new()
  WakuStore.init(peerManager, rng, store, wakuSwap, retentionPolicy)


proc isValidMessage(msg: WakuMessage): bool =
  if msg.timestamp == 0:
    return true

  let 
    now = getNanosecondTime(getTime().toUnixFloat())
    lowerBound = now - MaxMessageTimestampVariance
    upperBound = now + MaxMessageTimestampVariance

  return lowerBound <= msg.timestamp and msg.timestamp <= upperBound

proc handleMessage*(w: WakuStore, pubsubTopic: string, msg: WakuMessage) =
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
