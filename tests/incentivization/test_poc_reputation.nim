import
  std/options,
  testutils/unittests,
  chronos,
  web3,
  stew/byteutils,
  stint,
  strutils,
  tests/testlib/testasync,
  libp2p/[peerid, crypto/crypto]

import
  waku/[node/peer_manager, waku_core],
  waku/incentivization/[rpc, reputation_manager],
  waku/waku_lightpush/[rpc, common]

suite "Waku Incentivization PoC Reputation":
  var manager {.threadvar.}: ReputationManager
  var peerId1 {.threadvar.}: PeerId

  setup:
    manager = ReputationManager.init()
    peerId1 = PeerId.init(PrivateKey.random(ECDSA, (newRng())[]).tryGet()).tryGet()

  test "incentivization PoC: reputation: reputation table is empty after initialization":
    check manager.reputationOf.len == 0

  test "incentivization PoC: reputation: set and get reputation":
    manager.setReputation(peerId1, some(true)) # Encodes GoodRep
    check manager.getReputation(peerId1) == some(true)

  #[
    LightPushResponse* = object
    requestId*: string
    statusCode*: uint32
    statusDesc*: Option[string]
    relayPeerCount*: Option[uint32]

    LightpushStatusCode
    ]#

  test "incentivization PoC: reputation: evaluate LightPushResponse valid":
    let validLightLightPushResponse =
      LightPushResponse(requestId: "", statusCode: LightpushStatusCode.SUCCESS.uint32)
    # We expect evaluateResponse to return GoodResponse if isSuccess is true
    check evaluateResponse(validLightLightPushResponse) == GoodResponse

  test "incentivization PoC: reputation: evaluate LightPushResponse invalid":
    let invalidLightLightPushResponse = LightPushResponse(
      requestId: "", statusCode: LightpushStatusCode.SERVICE_NOT_AVAILABLE.uint32
    )
    check evaluateResponse(invalidLightLightPushResponse) == BadResponse

  test "incentivization PoC: reputation: updateReputationFromResponse valid":
    let validResp =
      LightPushResponse(requestId: "", statusCode: LightpushStatusCode.SUCCESS.uint32)
    manager.updateReputationFromResponse(peerId1, validResp)
    check manager.getReputation(peerId1) == some(true)

  test "incentivization PoC: reputation: updateReputationFromResponse invalid":
    let invalidResp = LightPushResponse(
      requestId: "", statusCode: LightpushStatusCode.SERVICE_NOT_AVAILABLE.uint32
    )
    manager.updateReputationFromResponse(peerId1, invalidResp)
    check manager.getReputation(peerId1) == some(false)

  test "incentivization PoC: reputation: default is None":
    check manager.getReputation(peerId1) == none(bool)
