{.push raises: [].}

import
  std/[options, sequtils, sets],
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import ../common/nimchronos, ../common/enr, ../waku_core, ../waku_enr, ./rpc

logScope:
  topics = "waku metadata"

const WakuMetadataCodec* = "/vac/waku/metadata/1.0.0"
const RpcResponseMaxBytes* = 1024

type WakuMetadata* = ref object of LPProtocol
  clusterId*: uint32
  shards*: HashSet[uint32]
  topicSubscriptionQueue: AsyncEventQueue[SubscriptionEvent]

proc respond(
    m: WakuMetadata, conn: Connection
): Future[Result[void, string]] {.async, gcsafe.} =
  let response =
    WakuMetadataResponse(clusterId: some(m.clusterId), shards: toSeq(m.shards))

  let res = catch:
    await conn.writeLP(response.encode().buffer)
  if res.isErr():
    return err(res.error.msg)

  return ok()

proc request*(
    m: WakuMetadata, conn: Connection
): Future[Result[WakuMetadataResponse, string]] {.async, gcsafe.} =
  let request =
    WakuMetadataRequest(clusterId: some(m.clusterId), shards: toSeq(m.shards))

  let writeRes = catch:
    await conn.writeLP(request.encode().buffer)
  let readRes = catch:
    await conn.readLp(RpcResponseMaxBytes)

  # close no watter what
  let closeRes = catch:
    await conn.closeWithEof()
  if closeRes.isErr():
    return err("close failed: " & closeRes.error.msg)

  if writeRes.isErr():
    return err("write failed: " & writeRes.error.msg)

  let buffer =
    if readRes.isErr():
      return err("read failed: " & readRes.error.msg)
    else:
      readRes.get()

  let response = WakuMetadataResponse.decode(buffer).valueOr:
    return err("decode failed: " & $error)

  return ok(response)

proc initProtocolHandler(m: WakuMetadata) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let res = catch:
      await conn.readLp(RpcResponseMaxBytes)
    let buffer = res.valueOr:
      error "Connection reading error", error = error.msg
      return

    let response = WakuMetadataResponse.decode(buffer).valueOr:
      error "Response decoding error", error = error
      return

    debug "Received WakuMetadata request",
      remoteClusterId = response.clusterId,
      remoteShards = response.shards,
      localClusterId = m.clusterId,
      localShards = m.shards

    discard await m.respond(conn)

    # close, no data is expected
    await conn.closeWithEof()

  m.handler = handle
  m.codec = WakuMetadataCodec

proc new*(
    T: type WakuMetadata,
    clusterId: uint32,
    enr: Record,
    queue: AsyncEventQueue[SubscriptionEvent],
): T =
  var (cluster, shards) = (clusterId, initHashSet[uint32]())

  let enrRes = enr.toTyped()
  if enrRes.isOk():
    let shardingRes = enrRes.get().relaySharding()
    if shardingRes.isSome():
      let relayShard = shardingRes.get()
      cluster = uint32(relayShard.clusterId)
      shards = toHashSet(relayShard.shardIds.mapIt(uint32(it)))

  let wm =
    WakuMetadata(clusterId: cluster, shards: shards, topicSubscriptionQueue: queue)

  wm.initProtocolHandler()

  info "Created WakuMetadata protocol", clusterId = wm.clusterId, shards = wm.shards

  return wm

proc subscriptionsListener(wm: WakuMetadata) {.async.} =
  ## Listen for pubsub topics subscriptions changes

  let key = wm.topicSubscriptionQueue.register()

  while wm.started:
    let events = await wm.topicSubscriptionQueue.waitEvents(key)

    for event in events:
      let parsedTopic = NsPubsubTopic.parse(event.topic).valueOr:
        continue

      if parsedTopic.kind != NsPubsubTopicKind.StaticSharding:
        continue

      if parsedTopic.clusterId != wm.clusterId:
        continue

      case event.kind
      of PubsubSub:
        wm.shards.incl(parsedTopic.shardId)
      of PubsubUnsub:
        wm.shards.excl(parsedTopic.shardId)
      else:
        continue

  wm.topicSubscriptionQueue.unregister(key)

proc start*(wm: WakuMetadata) =
  wm.started = true

  asyncSpawn wm.subscriptionsListener()

proc stop*(wm: WakuMetadata) =
  wm.started = false
