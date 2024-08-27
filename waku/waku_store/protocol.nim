## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md
{.push raises: [].}

import
  std/options,
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
  ./rpc_codec,
  ./protocol_metrics,
  ../common/rate_limit/request_limiter

logScope:
  topics = "waku store"

type StoreQueryRequestHandler* =
  proc(req: StoreQueryRequest): Future[StoreQueryResult] {.async, gcsafe.}

type WakuStore* = ref object of LPProtocol
  peerManager: PeerManager
  rng: ref rand.HmacDrbgContext
  requestHandler*: StoreQueryRequestHandler
  requestRateLimiter*: RequestRateLimiter

## Protocol

proc handleQueryRequest(
    self: WakuStore, requestor: PeerId, raw_request: seq[byte]
): Future[seq[byte]] {.async.} =
  var res = StoreQueryResponse()

  let req = StoreQueryRequest.decode(raw_request).valueOr:
    error "failed to decode rpc", peerId = requestor, error = $error
    waku_store_errors.inc(labelValues = [decodeRpcFailure])

    res.statusCode = uint32(ErrorCode.BAD_REQUEST)
    res.statusDesc = "decoding rpc failed: " & $error

    return res.encode().buffer

  let requestId = req.requestId

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
  let rejectReposnseBuffer = StoreQueryResponse(
    ## We will not copy and decode RPC buffer from stream only for requestId
    ## in reject case as it is comparably too expensive and opens possible
    ## attack surface
    requestId: "N/A",
    statusCode: uint32(ErrorCode.TOO_MANY_REQUESTS),
    statusDesc: $ErrorCode.TOO_MANY_REQUESTS,
  ).encode().buffer

  proc handler(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var resBuf: seq[byte]
    self.requestRateLimiter.checkUsageLimit(WakuStoreCodec, conn):
      let readRes = catch:
        await conn.readLp(DefaultMaxRpcSize.int)

      let reqBuf = readRes.valueOr:
        error "Connection read error", error = error.msg
        return

      waku_service_network_bytes.inc(
        amount = reqBuf.len().int64, labelValues = [WakuStoreCodec, "in"]
      )

      resBuf = await self.handleQueryRequest(conn.peerId, reqBuf)
    do:
      debug "store query request rejected due rate limit exceeded",
        peerId = conn.peerId, limit = $self.requestRateLimiter.setting
      resBuf = rejectReposnseBuffer

    let writeRes = catch:
      await conn.writeLp(resBuf)

    if writeRes.isErr():
      error "Connection write error", error = writeRes.error.msg
      return

    waku_service_network_bytes.inc(
      amount = resBuf.len().int64, labelValues = [WakuStoreCodec, "out"]
    )

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
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
  )

  store.initProtocolHandler()

  return store
