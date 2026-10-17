## Waku layer API — store (historical query) operations.
{.push raises: [].}

import
  chronos,
  chronicles,
  metrics,
  results,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport

import
  logos_delivery/kernel/kernel,
  logos_delivery/kernel/[common/time, protocols/message, node/peer_manager/peers],
  logos_delivery/kernel/protocols/codecs,
  logos_delivery/kernel/protocols/store/protocol as store,
  logos_delivery/kernel/protocols/store/client as store_client,
  logos_delivery/kernel/protocols/store/common as store_common,
  logos_delivery/kernel/protocols/store/rpc_codec as store_rpc_codec,
  logos_delivery/kernel/protocols/store/resume,
  logos_delivery/kernel/node/peer_manager/peer_manager,
  logos_delivery/kernel/common/rate_limit/setting,
  logos_delivery/kernel/
    [archive/common, archive/archive, archive/driver, archive/retention_policy]

logScope:
  topics = "waku node store api"

## Waku archive

import results, chronos, chronicles

import
  logos_delivery/kernel/[
    node/peer_manager/peers,
    protocols/codecs,
    node/peer_manager/peer_manager,
    protocols/store/common,
    protocols/store/client,
  ]

proc mountArchive*(
    self: Kernel, driver: ArchiveDriver, retentionPolicies = newSeq[RetentionPolicy]()
): Result[void, string] =
  self.protocols.archive = WakuArchive.new(
    driver = driver, retentionPolicies = retentionPolicies
  ).valueOr:
    return err("error in mountArchive: " & error)

  self.protocols.archive.start()

  return ok()

## Waku Store

proc toArchiveQuery(request: StoreQueryRequest): ArchiveQuery =
  var query = ArchiveQuery()

  query.includeData = request.includeData
  query.pubsubTopic = request.pubsubTopic
  query.contentTopics = request.contentTopics
  query.startTime = request.startTime
  query.endTime = request.endTime
  query.hashes = request.messageHashes
  query.cursor = request.paginationCursor
  query.direction = request.paginationForward
  query.requestId = request.requestId

  if request.paginationLimit.isSome():
    query.pageSize = uint(request.paginationLimit.get())

  return query

proc toStoreResult(res: ArchiveResult): StoreQueryResult =
  let response = res.valueOr:
    if error.kind == ArchiveErrorKind.INVALID_QUERY:
      return err(StoreError.new(400, "archive error: " & $error))
    return err(StoreError.new(300, "archive error: " & $error))

  var res = StoreQueryResponse()

  res.statusCode = 200
  res.statusDesc = "OK"

  for i in 0 ..< response.hashes.len:
    let hash = response.hashes[i]

    let kv = store_common.WakuMessageKeyValue(messageHash: hash)

    res.messages.add(kv)

  for i in 0 ..< response.messages.len:
    res.messages[i].message = Opt.some(response.messages[i])
    res.messages[i].pubsubTopic = Opt.some(response.topics[i])

  res.paginationCursor = response.cursor

  return ok(res)

proc mountStore*(
    self: Kernel, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
) {.async.} =
  if self.protocols.archive.isNil():
    error "failed to mount waku store protocol", error = "waku archive not set"
    return

  info "mounting waku store protocol"

  let requestHandler: StoreQueryRequestHandler = proc(
      request: StoreQueryRequest
  ): Future[StoreQueryResult] {.async.} =
    let request = request.toArchiveQuery()
    let response = await self.protocols.archive.findMessages(request)

    return response.toStoreResult()

  self.protocols.store =
    store.WakuStore.new(self.peerManager, self.rng, requestHandler, Opt.some(rateLimit))

  if self.started:
    await self.protocols.store.start()

  self.switch.mount(self.protocols.store, protocolMatcher(store_common.WakuStoreCodec))

proc mountStoreClient*(self: Kernel, maxMessageSize = int(DefaultMaxWakuMessageSize)) =
  ## `maxMessageSize` sets the largest store response that the client reads.
  info "mounting store client"

  self.protocols.storeClient = store_client.WakuStoreClient.new(
    self.peerManager, self.rng, maxQueryResponseSize(maxMessageSize)
  )

proc query*(
    self: Kernel, request: store_common.StoreQueryRequest, peer: RemotePeerInfo
): Future[store_common.WakuStoreResult[store_common.StoreQueryResponse]] {.
    async, gcsafe
.} =
  ## Queries known nodes for historical messages
  if self.protocols.storeClient.isNil():
    return err("waku store v3 client is nil")

  let response = (await self.protocols.storeClient.query(request, peer)).valueOr:
    var res = StoreQueryResponse()
    res.statusCode = uint32(error.kind)
    res.statusDesc = $error

    return ok(res)

  return ok(response)

proc setupStoreResume*(self: Kernel) =
  self.protocols.storeResume = StoreResume.new(
    self.peerManager, self.protocols.archive, self.protocols.storeClient
  ).valueOr:
    error "Failed to setup Store Resume", error = $error
    return

proc isStoreMounted*(self: Kernel): bool =
  ## True if a store client is mounted (the node can run store queries).
  return not self.protocols.storeClient.isNil()

proc hasStorePeer*(self: Kernel): bool =
  ## True if at least one store service peer is available to query.
  return self.peerManager.selectPeer(WakuStoreCodec).isSome()

proc storeQueryToAny*(
    self: Kernel, request: StoreQueryRequest
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Runs a store query against any available store peer (retries across peers).
  try:
    if self.protocols.storeClient.isNil():
      return err("wakuStoreClient is not mounted")

    let queryResponse = (await self.protocols.storeClient.queryToAny(request)).valueOr:
      return err($error)

    return ok(queryResponse)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    return err(e.msg)

proc storeQuery*(
    self: Kernel, request: StoreQueryRequest, peer: string, timeoutMs: int
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Runs a store query against one store peer. `peer` is one fully qualified
  ## multiaddress, or several for the same peer separated by commas.
  try:
    if self.protocols.storeClient.isNil():
      return err("wakuStoreClient is not mounted")

    let remotePeer = parsePeerAddrList(peer).valueOr:
      return err("storeQuery failed to parse peer addr: " & $error)

    let queryFut = self.protocols.storeClient.query(request, remotePeer)
    if not await queryFut.withTimeout(timeoutMs.milliseconds):
      return err("storeQuery timed out")

    let queryResponse = queryFut.read().valueOr:
      return err("storeQuery failed: " & $error)

    return ok(queryResponse)
  except CatchableError as e:
    return err(e.msg)
