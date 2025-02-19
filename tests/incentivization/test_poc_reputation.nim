import
  std/options,
  testutils/unittests,
  chronos,
  web3,
  stew/byteutils,
  stint,
  strutils,
  tests/testlib/testasync

import
  waku/[node/peer_manager, waku_core],
  waku/incentivization/[rpc, reputation_manager],
  waku/waku_lightpush/rpc

suite "Waku Incentivization PoC Reputation":
  var manager {.threadvar.}: ReputationManager

  setup:
    manager = ReputationManager.init()

  test "incentivization PoC: reputation: reputation table is empty after initialization":
    check manager.peerReputation.len == 0

  test "incentivization PoC: reputation: set and get reputation":
    manager.setReputation("peer1", GoodRep)
    check manager.getReputation("peer1") == GoodRep

  test "incentivization PoC: reputation: evaluate PushResponse valid":
    let validLightpushResponse =
      PushResponse(isSuccess: true, info: some("Everything is OK"))
    # We expect evaluateResponse to return GoodRep if isSuccess is true
    check evaluateResponse(validLightpushResponse) == GoodRep

  test "incentivization PoC: reputation: evaluate PushResponse invalid":
    # For example, set isSuccess = false so we expect a returned BadRep
    let invalidLightpushResponse = PushResponse(isSuccess: false, info: none(string))
    check evaluateResponse(invalidLightpushResponse) == BadRep
