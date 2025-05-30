## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md
{.push raises: [].}

import
  std/[options, times],
  results,
  chronicles,
  chronos,
  bearssl/rand,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  metrics
import
  ../waku_core,
  ../node/peer_manager,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics,
  ../common/rate_limit/request_limiter

logScope:
  topics = "waku legacy store"

type HistoryQueryHandler* =
  proc(req: HistoryQuery): Future[HistoryResult] {.async, gcsafe.}

type WakuStore* = ref object of LPProtocol
  peerManager: PeerManager
  rng: ref rand.HmacDrbgContext
  queryHandler*: HistoryQueryHandler
  requestRateLimiter*: RequestRateLimiter

## Protocol

type StoreResp = tuple[resp: seq[byte], requestId: string]

proc handleLegacyQueryRequest(
    self: WakuStore, requestor: PeerId, raw_request: seq[byte]
): Future[StoreResp] {.async.} =
  let decodeRes = HistoryRPC.decode(raw_request)
  if decodeRes.isErr():
    error "failed to decode rpc", peerId = requestor, error = $decodeRes.error
    waku_legacy_store_errors.inc(labelValues = [decodeRpcFailure])
    return (newSeq[byte](), "failed to decode rpc")

  let reqRpc = decodeRes.value

  if reqRpc.query.isNone():
    error "empty query rpc", peerId = requestor, requestId = reqRpc.requestId
    waku_legacy_store_errors.inc(labelValues = [emptyRpcQueryFailure])
    return (newSeq[byte](), "empty query rpc")

  let requestId = reqRpc.requestId
  var request = reqRpc.query.get().toAPI()
  request.requestId = requestId

  info "received history query",
    peerId = requestor, requestId = requestId, query = request
  waku_legacy_store_queries.inc()

  var responseRes: HistoryResult
  try:
    responseRes = await self.queryHandler(request)
  except Exception:
    error "history query failed",
      peerId = requestor, requestId = requestId, error = getCurrentExceptionMsg()

    let error = HistoryError(kind: HistoryErrorKind.UNKNOWN).toRPC()
    let response = HistoryResponseRPC(error: error)
    return (
      HistoryRPC(requestId: requestId, response: some(response)).encode().buffer,
      requestId,
    )

  if responseRes.isErr():
    error "history query failed",
      peerId = requestor, requestId = requestId, error = responseRes.error

    let response = responseRes.toRPC()
    return (
      HistoryRPC(requestId: requestId, response: some(response)).encode().buffer,
      requestId,
    )

  let response = responseRes.toRPC()

  info "sending history response",
    peerId = requestor, requestId = requestId, messages = response.messages.len

  return (
    HistoryRPC(requestId: requestId, response: some(response)).encode().buffer,
    requestId,
  )

proc initProtocolHandler(ws: WakuStore) =
  let rejectResponseBuf = HistoryRPC(
    ## We will not copy and decode RPC buffer from stream only for requestId
    ## in reject case as it is comparably too expensive and opens possible
    ## attack surface
    requestId: "N/A",
    response: some(
      HistoryResponseRPC(
        error: HistoryError(kind: HistoryErrorKind.TOO_MANY_REQUESTS).toRPC()
      )
    ),
  ).encode().buffer

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var successfulQuery = false ## only consider the correct queries in metrics
    var resBuf: StoreResp
    var queryDuration: float
    ws.requestRateLimiter.checkUsageLimit(WakuLegacyStoreCodec, conn):
      let readRes = catch:
        await conn.readLp(DefaultMaxRpcSize.int)

      let reqBuf = readRes.valueOr:
        error "Connection read error", error = error.msg
        return

      waku_service_network_bytes.inc(
        amount = reqBuf.len().int64, labelValues = [WakuLegacyStoreCodec, "in"]
      )

      let queryStartTime = getTime().toUnixFloat()
      try:
        resBuf = await ws.handleLegacyQueryRequest(conn.peerId, reqBuf)
      except CatchableError:
        error "legacy store query handler failed",
          remote_peer_id = conn.peerId, error = getCurrentExceptionMsg()
        return

      queryDuration = getTime().toUnixFloat() - queryStartTime
      waku_legacy_store_time_seconds.set(queryDuration, ["query-db-time"])
      successfulQuery = true
    do:
      debug "Legacy store query request rejected due rate limit exceeded",
        peerId = conn.peerId, limit = $ws.requestRateLimiter.setting
      resBuf = (rejectResponseBuf, "rejected")

    let writeRespStartTime = getTime().toUnixFloat()
    let writeRes = catch:
      await conn.writeLp(resBuf.resp)

    if writeRes.isErr():
      error "Connection write error", error = writeRes.error.msg
      return

    if successfulQuery:
      let writeDuration = getTime().toUnixFloat() - writeRespStartTime
      waku_legacy_store_time_seconds.set(writeDuration, ["send-store-resp-time"])
      debug "after sending response",
        requestId = resBuf.requestId,
        queryDurationSecs = queryDuration,
        writeStreamDurationSecs = writeDuration

    waku_service_network_bytes.inc(
      amount = resBuf.resp.len().int64, labelValues = [WakuLegacyStoreCodec, "out"]
    )

  ws.handler = handler
  ws.codec = WakuLegacyStoreCodec

proc new*(
    T: type WakuStore,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    queryHandler: HistoryQueryHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  # Raise a defect if history query handler is nil
  if queryHandler.isNil():
    raise newException(NilAccessDefect, "history query handler is nil")

  let ws = WakuStore(
    rng: rng,
    peerManager: peerManager,
    queryHandler: queryHandler,
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
  )
  ws.initProtocolHandler()
  setServiceLimitMetric(WakuLegacyStoreCodec, rateLimitSetting)
  ws
