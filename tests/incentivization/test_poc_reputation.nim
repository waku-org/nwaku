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

  test "incentivization PoC: reputation: evaluate LightPushResponse valid":
    let validLightLightPushResponse =
      LightPushResponse(requestId: "", statusCode: LightPushSuccessCode.SUCCESS)
    # We expect evaluateResponse to return GoodResponse if isSuccess is true
    check evaluateResponse(validLightLightPushResponse) == GoodResponse

  test "incentivization PoC: reputation: evaluate LightPushResponse invalid":
    let invalidLightLightPushResponse = LightPushResponse(
      requestId: "", statusCode: LightPushErrorCode.SERVICE_NOT_AVAILABLE
    )
    check evaluateResponse(invalidLightLightPushResponse) == BadResponse

  test "incentivization PoC: reputation: evaluate LightPushResponse neutral - payment required":
    let neutralLightPushResponse = LightPushResponse(
      requestId: "", statusCode: LightPushErrorCode.PAYMENT_REQUIRED
    )
    check evaluateResponse(neutralLightPushResponse) == NeutralResponse

  test "incentivization PoC: reputation: evaluate LightPushResponse bad - no peers":
    let badLightPushResponse = LightPushResponse(
      requestId: "", statusCode: LightPushErrorCode.NO_PEERS_TO_RELAY
    )
    check evaluateResponse(badLightPushResponse) == BadResponse

  test "incentivization PoC: reputation: updateReputationFromResponse valid":
    let validResp =
      LightPushResponse(requestId: "", statusCode: LightPushSuccessCode.SUCCESS)
    manager.updateReputationFromResponse(peerId1, validResp)
    check manager.getReputation(peerId1) == some(true)

  test "incentivization PoC: reputation: updateReputationFromResponse invalid":
    let invalidResp = LightPushResponse(
      requestId: "", statusCode: LightPushErrorCode.SERVICE_NOT_AVAILABLE
    )
    manager.updateReputationFromResponse(peerId1, invalidResp)
    check manager.getReputation(peerId1) == some(false)

  test "incentivization PoC: reputation: updateReputationFromResponse neutral - no change":
    # First set a good reputation
    manager.setReputation(peerId1, some(true))
    check manager.getReputation(peerId1) == some(true)
    
    # Send a neutral response (payment required)
    let neutralResp = LightPushResponse(
      requestId: "", statusCode: LightPushErrorCode.PAYMENT_REQUIRED
    )
    manager.updateReputationFromResponse(peerId1, neutralResp)
    
    # Reputation should remain unchanged
    check manager.getReputation(peerId1) == some(true)

  test "incentivization PoC: reputation: updateReputationFromResponse neutral - no change from bad":
    # First set a bad reputation
    manager.setReputation(peerId1, some(false))
    check manager.getReputation(peerId1) == some(false)
    
    # Send a neutral response (payment required)
    let neutralResp = LightPushResponse(
      requestId: "", statusCode: LightPushErrorCode.PAYMENT_REQUIRED
    )
    manager.updateReputationFromResponse(peerId1, neutralResp)
    
    # Reputation should remain unchanged
    check manager.getReputation(peerId1) == some(false)

  test "incentivization PoC: reputation: updateReputationFromResponse neutral - no change from none":
    # Start with no reputation set
    check manager.getReputation(peerId1) == none(bool)
    
    # Send a neutral response (payment required)
    let neutralResp = LightPushResponse(
      requestId: "", statusCode: LightPushErrorCode.PAYMENT_REQUIRED
    )
    manager.updateReputationFromResponse(peerId1, neutralResp)
    
    # Reputation should remain none
    check manager.getReputation(peerId1) == none(bool)

  test "incentivization PoC: reputation: default is None":
    check manager.getReputation(peerId1) == none(bool)
