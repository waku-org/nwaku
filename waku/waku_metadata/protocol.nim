{.push raises: [].}

import
  std/[options],
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto
import ../common/nimchronos, ../waku_core, ./rpc, ../common/shard_subscription_monitor

from ../waku_core/codecs import WakuMetadataCodec
export WakuMetadataCodec

logScope:
  topics = "waku metadata"

const RpcResponseMaxBytes* = 1024

type WakuMetadata* = ref object of LPProtocol
  clusterId*: uint32
  shardSubscriptionMonitor: ShardsSubscriptionMonitor

proc respond(
    m: WakuMetadata, conn: Connection
): Future[Result[void, string]] {.async, gcsafe.} =
  let response = WakuMetadataResponse(
    clusterId: some(m.clusterId.uint32),
    shards: m.shardSubscriptionMonitor.getSubscribedShardsUint32(),
  )

  let res = catch:
    await conn.writeLP(response.encode().buffer)
  if res.isErr():
    return err(res.error.msg)

  return ok()

proc request*(
    m: WakuMetadata, conn: Connection
): Future[Result[WakuMetadataResponse, string]] {.async, gcsafe.} =
  let request = WakuMetadataRequest(
    clusterId: some(m.clusterId),
    shards: m.shardSubscriptionMonitor.getSubscribedShardsUint32(),
  )

  let writeRes = catch:
    await conn.writeLP(request.encode().buffer)
  let readRes = catch:
    await conn.readLp(RpcResponseMaxBytes)

  # close no matter what
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
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    defer:
      # close, no data is expected
      await conn.closeWithEof()

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
      localShards = m.shardSubscriptionMonitor.getSubscribedShards(),
      peer = conn.peerId

    try:
      discard await m.respond(conn)
    except CatchableError:
      error "Failed to respond to WakuMetadata request",
        error = getCurrentExceptionMsg()

  m.handler = handler
  m.codec = WakuMetadataCodec

proc new*(
    T: type WakuMetadata,
    clusterId: uint32,
    shardSubscriptionMonitor: ShardsSubscriptionMonitor,
): T =
  let wm = WakuMetadata(
    clusterId: clusterId, shardSubscriptionMonitor: shardSubscriptionMonitor
  )

  wm.initProtocolHandler()

  info "Created WakuMetadata protocol",
    clusterId = wm.clusterId, shards = wm.shardSubscriptionMonitor.getSubscribedShards()

  return wm

proc start*(wm: WakuMetadata) =
  wm.started = true

proc stop*(wm: WakuMetadata) =
  wm.started = false
