## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
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
  ../waku_core,
  ../node/peer_manager,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics,
  ../common/ratelimit,
  ../common/waku_service_metrics

logScope:
  topics = "waku legacy store"

const MaxMessageTimestampVariance* = getNanoSecondTime(20)
  # 20 seconds maximum allowable sender timestamp "drift"

type HistoryQueryHandler* =
  proc(req: HistoryQuery): Future[HistoryResult] {.async, gcsafe.}

type WakuStore* = ref object of LPProtocol
  peerManager: PeerManager
  rng: ref rand.HmacDrbgContext
  queryHandler*: HistoryQueryHandler
  requestRateLimiter*: Option[TokenBucket]

## Protocol

proc handleLegacyQueryRequest(
    self: WakuStore, requestor: PeerId, raw_request: seq[byte]
): Future[seq[byte]] {.async.} =
  let decodeRes = HistoryRPC.decode(raw_request)
  if decodeRes.isErr():
    error "failed to decode rpc", peerId = requestor
    waku_legacy_store_errors.inc(labelValues = [decodeRpcFailure])
    # TODO: Return (BAD_REQUEST, cause: "decode rpc failed")
    return

  let reqRpc = decodeRes.value

  if reqRpc.query.isNone():
    error "empty query rpc", peerId = requestor, requestId = reqRpc.requestId
    waku_legacy_store_errors.inc(labelValues = [emptyRpcQueryFailure])
    # TODO: Return (BAD_REQUEST, cause: "empty query")
    return

  let
    requestId = reqRpc.requestId
    request = reqRpc.query.get().toAPI()

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
    return HistoryRPC(requestId: requestId, response: some(response)).encode().buffer

  if responseRes.isErr():
    error "history query failed",
      peerId = requestor, requestId = requestId, error = responseRes.error

    let response = responseRes.toRPC()
    return HistoryRPC(requestId: requestId, response: some(response)).encode().buffer

  let response = responseRes.toRPC()

  info "sending history response",
    peerId = requestor, requestId = requestId, messages = response.messages.len

  return HistoryRPC(requestId: requestId, response: some(response)).encode().buffer

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

  proc handler(conn: Connection, proto: string) {.async, closure.} =
    var resBuf: seq[byte]
    ws.requestRateLimiter.checkUsageLimit(WakuLegacyStoreCodec, conn):
      let readRes = catch:
        await conn.readLp(DefaultMaxRpcSize.int)

      let reqBuf = readRes.valueOr:
        error "Connection read error", error = error.msg
        return

      waku_service_inbound_network_bytes.inc(
        amount = reqBuf.len().int64, labelValues = [WakuLegacyStoreCodec]
      )

      resBuf = await ws.handleLegacyQueryRequest(conn.peerId, reqBuf)
    do:
      debug "Legacy store query request rejected due rate limit exceeded",
        peerId = conn.peerId
      resBuf = rejectResponseBuf

    let writeRes = catch:
      await conn.writeLp(resBuf)

    if writeRes.isErr():
      error "Connection write error", error = writeRes.error.msg
      return

    waku_service_outbound_network_bytes.inc(
      amount = resBuf.len().int64, labelValues = [WakuLegacyStoreCodec]
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
    requestRateLimiter: newTokenBucket(rateLimitSetting),
  )
  ws.initProtocolHandler()
  ws
