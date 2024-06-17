import std/options, chronicles, chronos, libp2p/protocols/protocol
import
  ../node/peer_manager, ../waku_core, ./common, ./rpc_codec, ./rpc

logScope:
  topics = "waku incentivization PoC client"

type WakuDummyClient* = ref object
  peerManager*: PeerManager

proc new*(
    T: type WakuDummyClient, peerManager: PeerManager): T =
  WakuDummyClient(peerManager: peerManager)

proc sendDummyRequest(
    dummyClient: WakuDummyClient, dummyRequest: DummyRequest, peer: PeerId | RemotePeerInfo
): Future[DummyResult[void]] {.async, gcsafe.} =
  let connOpt = await dummyClient.peerManager.dialPeer(peer, DummyCodec)
  if connOpt.isNone():
    return err("dialFailure")
  let connection = connOpt.get()
  await connection.writeLP(dummyRequest.encode().buffer)

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    return err("Exception reading: " & getCurrentExceptionMsg())

  let decodeRespRes = DummyResponse.decode(buffer)
  if decodeRespRes.isErr():
    return err("decodeRpcFailure")

  let dummyResponse = decodeRespRes.get()

  let requestId = dummyResponse.requestId
  let eligibilityStatus = dummyResponse.eligibilityStatus
  let statusCode = eligibilityStatus.statusCode
  # status description is optional
  var statusDesc = ""
  let statusDescRes = eligibilityStatus.statusDesc
  if statusDescRes.isSome():
    statusDesc = statusDescRes.get()

  if statusCode == 200:
    return ok()
  else:
    return err(statusDesc)

proc sendRequest*(
    dummyClient: WakuDummyClient,
    dummyRequest: DummyRequest,
    peer: PeerId | RemotePeerInfo,
): Future[DummyResult[void]] {.async, gcsafe.} =
  return await dummyClient.sendDummyRequest(dummyRequest, peer)
