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

proc initProtocolHandler(ws: WakuStore) =
  proc handler(conn: Connection, proto: string) {.async.} =
    let buf = await conn.readLp(DefaultMaxRpcSize.int)

    let decodeRes = HistoryRPC.decode(buf)
    if decodeRes.isErr():
      error "failed to decode rpc", peerId = $conn.peerId
      waku_legacy_store_errors.inc(labelValues = [decodeRpcFailure])
      # TODO: Return (BAD_REQUEST, cause: "decode rpc failed")
      return

    let reqRpc = decodeRes.value

    if reqRpc.query.isNone():
      error "empty query rpc", peerId = $conn.peerId, requestId = reqRpc.requestId
      waku_legacy_store_errors.inc(labelValues = [emptyRpcQueryFailure])
      # TODO: Return (BAD_REQUEST, cause: "empty query")
      return

    if ws.requestRateLimiter.isSome() and not ws.requestRateLimiter.get().tryConsume(1):
      trace "store query request rejected due rate limit exceeded",
        peerId = $conn.peerId, requestId = reqRpc.requestId
      let error = HistoryError(kind: HistoryErrorKind.TOO_MANY_REQUESTS).toRPC()
      let response = HistoryResponseRPC(error: error)
      let rpc = HistoryRPC(requestId: reqRpc.requestId, response: some(response))
      await conn.writeLp(rpc.encode().buffer)
      waku_service_requests_rejected.inc(labelValues = ["Store"])
      return

    waku_service_requests.inc(labelValues = ["Store"])

    let
      requestId = reqRpc.requestId
      request = reqRpc.query.get().toAPI()

    info "received history query",
      peerId = conn.peerId, requestId = requestId, query = request
    waku_legacy_store_queries.inc()

    var responseRes: HistoryResult
    try:
      responseRes = await ws.queryHandler(request)
    except Exception:
      error "history query failed",
        peerId = $conn.peerId, requestId = requestId, error = getCurrentExceptionMsg()

      let error = HistoryError(kind: HistoryErrorKind.UNKNOWN).toRPC()
      let response = HistoryResponseRPC(error: error)
      let rpc = HistoryRPC(requestId: requestId, response: some(response))
      await conn.writeLp(rpc.encode().buffer)
      return

    if responseRes.isErr():
      error "history query failed",
        peerId = $conn.peerId, requestId = requestId, error = responseRes.error

      let response = responseRes.toRPC()
      let rpc = HistoryRPC(requestId: requestId, response: some(response))
      await conn.writeLp(rpc.encode().buffer)
      return

    let response = responseRes.toRPC()

    info "sending history response",
      peerId = conn.peerId, requestId = requestId, messages = response.messages.len

    let rpc = HistoryRPC(requestId: requestId, response: some(response))
    await conn.writeLp(rpc.encode().buffer)

  ws.handler = handler
  ws.codec = WakuStoreCodec

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
