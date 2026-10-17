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
  ../../kernel,
  logos_delivery/kernel/core/[ time, message, peers], logos_delivery/kernel/protocols/codecs,
  logos_delivery/kernel/protocols/store/protocol as store,
  logos_delivery/kernel/protocols/store/client as store_client,
  logos_delivery/kernel/protocols/store/common as store_common,
  logos_delivery/kernel/protocols/store/rpc_codec as store_rpc_codec,
  logos_delivery/kernel/protocols/store/resume,
  logos_delivery/kernel/node/peer_manager/peer_manager,
  ../../common/rate_limit/setting,
  logos_delivery/kernel/[archive/common, archive/archive, archive/driver, archive/retention_policy]

logScope:
  topics = "waku node store api"

## Waku archive
proc mountArchive*(
    node: Kernel,
    driver: ArchiveDriver,
    retentionPolicies = newSeq[RetentionPolicy](),
): Result[void, string] =
  node.protocols.archive = WakuArchive.new(
    driver = driver, retentionPolicies = retentionPolicies
  ).valueOr:
    return err("error in mountArchive: " & error)

  node.protocols.archive.start()

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
    node: Kernel, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
) {.async.} =
  if node.protocols.archive.isNil():
    error "failed to mount waku store protocol", error = "waku archive not set"
    return

  info "mounting waku store protocol"

  let requestHandler: StoreQueryRequestHandler = proc(
      request: StoreQueryRequest
  ): Future[StoreQueryResult] {.async.} =
    let request = request.toArchiveQuery()
    let response = await node.protocols.archive.findMessages(request)

    return response.toStoreResult()

  node.protocols.store =
    store.WakuStore.new(node.peerManager, node.rng, requestHandler, Opt.some(rateLimit))

  if node.started:
    await node.protocols.store.start()

  node.switch.mount(node.protocols.store, protocolMatcher(store_common.WakuStoreCodec))

proc mountStoreClient*(node: Kernel, maxMessageSize = int(DefaultMaxWakuMessageSize)) =
  ## `maxMessageSize` sets the largest store response that the client reads.
  info "mounting store client"

  node.protocols.storeClient = store_client.WakuStoreClient.new(
    node.peerManager, node.rng, maxQueryResponseSize(maxMessageSize)
  )

proc query*(
    node: Kernel, request: store_common.StoreQueryRequest, peer: RemotePeerInfo
): Future[store_common.WakuStoreResult[store_common.StoreQueryResponse]] {.
    async, gcsafe
.} =
  ## Queries known nodes for historical messages
  if node.protocols.storeClient.isNil():
    return err("waku store v3 client is nil")

  let response = (await node.protocols.storeClient.query(request, peer)).valueOr:
    var res = StoreQueryResponse()
    res.statusCode = uint32(error.kind)
    res.statusDesc = $error

    return ok(res)

  return ok(response)

proc setupStoreResume*(node: Kernel) =
  node.protocols.storeResume = StoreResume.new(
    node.peerManager, node.protocols.archive, node.protocols.storeClient
  ).valueOr:
    error "Failed to setup Store Resume", error = $error
    return
