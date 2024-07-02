import
  std/[options, sequtils, sets, strutils, tables],
  stew/byteutils,
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/protocol
import
  ../node/peer_manager,
  ../waku_core,
  ./common,
  ./rpc_codec,
  ./rpc,
  ./eligibility

logScope:
  topics = "waku incentivization PoC"

type DummyProtocol* = ref object of LPProtocol
  peerManager*: PeerManager
  dummyHandler*: DummyHandler
  ethClient*: string

proc handleRequest*(
    dummyProtocol: DummyProtocol, peerId: PeerId, buffer: seq[byte]
    ): Future[DummyResponse] {.async.} =
  let reqDecodeRes = DummyRequest.decode(buffer)
  var isProofValid = false
  var requestId = ""
  if reqDecodeRes.isOk():
    let dummyRequest = reqDecodeRes.get()
    let eligibilityProof = dummyRequest.eligibilityProof
    requestId = dummyRequest.requestId
    isProofValid = await isEligible(eligibilityProof, dummyProtocol.ethClient)
  let response = genDummyResponseWithEligibilityStatus(isProofValid, requestId)
  return response

proc initProtocolHandler(dummyProtocol: DummyProtocol) =
  proc handle(conn: Connection, proto: string) {.async.} =
    let buffer = await conn.readLp(DefaultMaxRpcSize)
    var dummyResponse = await handleRequest(dummyProtocol, conn.peerId, buffer)
    await conn.writeLp(dummyResponse.encode().buffer)

  dummyProtocol.handler = handle
  dummyProtocol.codec = DummyCodec

proc new*(
    T: type DummyProtocol,
    peerManager: PeerManager,
    dummyHandler: DummyHandler,
    ethClient: string,
  ): T =
  let dummyProtocol = DummyProtocol(
    peerManager: peerManager,
    dummyHandler: dummyHandler,
    ethClient: ethClient
  )
  dummyProtocol.initProtocolHandler()
  return dummyProtocol

