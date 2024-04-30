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
  ./rpc_codec,
  ./protocol_metrics,
  ../common/ratelimit,
  ../common/waku_service_metrics

logScope:
  topics = "waku store"

const MaxMessageTimestampVariance* = getNanoSecondTime(20)
  # 20 seconds maximum allowable sender timestamp "drift"

type StoreQueryRequestHandler* =
  proc(req: StoreQueryRequest): Future[StoreQueryResult] {.async, gcsafe.}

type WakuStore* = ref object of LPProtocol
  peerManager: PeerManager
  rng: ref rand.HmacDrbgContext
  requestHandler*: StoreQueryRequestHandler
  requestRateLimiter*: Option[TokenBucket]

## Protocol

proc handleQueryRequest*(
    self: WakuStore, requestor: PeerId, raw_request: seq[byte]
): Future[seq[byte]] {.async.} =
  var res = StoreQueryResponse()

  let req = StoreQueryRequest.decode(raw_request).valueOr:
    error "failed to decode rpc", peerId = requestor, error = $error
    waku_store_errors.inc(labelValues = [decodeRpcFailure])

    res.statusCode = uint32(ErrorCode.BAD_REQUEST)
    res.statusDesc = "decode rpc failed " & $error

    return res.encode().buffer

  let requestId = req.requestId

  if self.requestRateLimiter.isSome() and not self.requestRateLimiter.get().tryConsume(
    1
  ):
    debug "store query request rejected due rate limit exceeded",
      peerId = $requestor, requestId = requestId

    res.statusCode = uint32(ErrorCode.TOO_MANY_REQUESTS)
    res.statusDesc = $ErrorCode.TOO_MANY_REQUESTS

    waku_service_requests_rejected.inc(labelValues = ["Store"])

    return res.encode().buffer

  waku_service_requests.inc(labelValues = ["Store"])

  info "received store query request",
    peerId = requestor, requestId = requestId, request = req
  waku_store_queries.inc()

  let queryResult = await self.requestHandler(req)

  res = queryResult.valueOr:
    error "store query failed",
      peerId = requestor, requestId = requestId, error = $error

    res.statusCode = uint32(error.kind)
    res.statusDesc = $error

    return res.encode().buffer

  res.requestId = requestId
  res.statusCode = 200
  res.statusDesc = "OK"

  info "sending store query response",
    peerId = requestor, requestId = requestId, messages = res.messages.len

  return res.encode().buffer

proc initProtocolHandler(self: WakuStore) =
  proc handler(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let readRes = catch:
      await conn.readLp(DefaultMaxRpcSize.int)

    let reqBuf = readRes.valueOr:
      error "Connection read error", error = error.msg
      return

    let resBuf = await self.handleQueryRequest(conn.peerId, reqBuf)

    let writeRes = catch:
      await conn.writeLp(resBuf)

    if writeRes.isErr():
      error "Connection write error", error = writeRes.error.msg
      return

  self.handler = handler
  self.codec = WakuStoreCodec

proc new*(
    T: type WakuStore,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    requestHandler: StoreQueryRequestHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  if requestHandler.isNil(): # TODO use an Option instead ???
    raise newException(NilAccessDefect, "history query handler is nil")

  let store = WakuStore(
    rng: rng,
    peerManager: peerManager,
    requestHandler: requestHandler,
    requestRateLimiter: newTokenBucket(rateLimitSetting),
  )

  store.initProtocolHandler()

  return store
