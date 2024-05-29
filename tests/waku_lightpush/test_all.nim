import ./test_client, ./test_ratelimit

# import std/[unittest, options, times]
# import ../../../waku/[
#     waku_lightpush/protocol,
#     waku_rln_relay/rln_relay,
#     waku_core,
#     node/peer_manager/peer_manager
# ]

# suite "LightPush with RLN":
#   test "handleRequest with valid RLN proof":
#     let peerManager = PeerManager()
#     let rng = initHmacDrbgContext()
#     let rlnPeer = WakuRLNRelay()
#     let pushHandler: PushMessageHandler = proc (peerId, topic, msg): Future[Result[void, string]] {.async.} =
#       return ok()

#     let wl = WakuLightPush(
#       peerManager: peerManager,
#       rng: rng,
#       pushHandler: pushHandler,
#       rlnPeer: rlnPeer,
#     )

#     # Prepare a valid WakuMessage
#     let payload = "Hello, Waku!".toBytes()
#     let contentTopic = "/waku/2/default-content/proto"
#     var message = WakuMessage(payload: payload, contentTopic: contentTopic)

#     # Append RLN proof to the message
#     let senderEpochTime = rlnPeer.calcEpoch(epochTime())
#     let appendProofRes = rlnPeer.appendRLNProof(message, senderEpochTime)
#     doAssert appendProofRes.isOk(), "Failed to append RLN proof: " & appendProofRes.error

#     # Prepare a valid PushRPC request
#     let pushRequest = PushRequest(pubSubTopic: contentTopic, message: message)
#     let pushRpc = PushRPC(requestId: "1", request: some(pushRequest))
#     let buffer = pushRpc.encode().buffer

#     # Call handleRequest and check the result
#     let result = waitFor wl.handleRequest("peer1", buffer)
#     check result.response.isSome
#     check result.response.get().isSuccess

