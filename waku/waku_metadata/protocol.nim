when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, sequtils, random],
  stew/results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../common/nimchronos,
  ../waku_core,
  ./rpc

logScope:
  topics = "waku metadata"

const WakuMetadataCodec* = "/vac/waku/metadata/1.0.0"
const RpcResponseMaxBytes* = 1024

type
  WakuMetadata* = ref object of LPProtocol
    clusterId*: uint32
    shards*: seq[uint32]

proc respond(m: WakuMetadata, conn: Connection): Future[Result[void, string]] {.async, gcsafe.} =
  try:
    await conn.writeLP(WakuMetadataResponse(
      clusterId: some(m.clusterId),
      shards: m.shards
      ).encode().buffer)
  except CatchableError as exc:
    return err(exc.msg)

  return ok()

proc request*(m: WakuMetadata, conn: Connection): Future[Result[WakuMetadataResponse, string]] {.async, gcsafe.} =
  var buffer: seq[byte]
  var error: string
  try:
    await conn.writeLP(WakuMetadataRequest(
      clusterId: some(m.clusterId),
      shards: m.shards,
    ).encode().buffer)
    buffer = await conn.readLp(RpcResponseMaxBytes)
  except CatchableError as exc:
    error = $exc.msg
  finally:
    # close, no more data is expected
    await conn.closeWithEof()

  if error.len > 0:
    return err("write/read failed: " & error)

  let decodedBuff = WakuMetadataResponse.decode(buffer)
  if decodedBuff.isErr():
    return err("decode failed: " & $decodedBuff.error)

  echo decodedBuff.get().clusterId
  return ok(decodedBuff.get())

proc initProtocolHandler*(m: WakuMetadata) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var buffer: seq[byte]
    try:
      buffer = await conn.readLp(RpcResponseMaxBytes)
    except CatchableError as exc:
      return

    let decBuf = WakuMetadataResponse.decode(buffer)
    if decBuf.isErr():
      return

    let response = decBuf.get()
    debug "Received WakuMetadata request",
      remoteClusterId=response.clusterId,
      remoteShards=response.shards,
      localClusterId=m.clusterId,
      localShards=m.shards

    discard await m.respond(conn)

    # close, no data is expected
    await conn.closeWithEof()

  m.handler = handle
  m.codec = WakuMetadataCodec

proc new*(T: type WakuMetadata, clusterId: uint32): T =
  let m = WakuMetadata(
    clusterId: clusterId,
    # TODO: must be updated real time
    shards: @[],
    )
  m.initProtocolHandler()
  info "Created WakuMetadata protocol", clusterId=clusterId
  return m
