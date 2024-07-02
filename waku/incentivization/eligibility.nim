import
  std/options,
  std/strscans,
  std/sequtils,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import stew/results, libp2p/peerid

import
  ../../../waku/incentivization/rpc,
  ../../../waku/incentivization/rpc_codec,
  ../../../waku/incentivization/common,
  ../../../waku/incentivization/txid_proof


proc isEligible*(eligibilityProof: EligibilityProof, ethClient: string): Future[bool] {.async.} =
  result = await txidEligiblityCriteriaMet(eligibilityProof, ethClient)

proc genDummyResponseWithEligibilityStatus*(proofValid: bool, requestId: string = ""): DummyResponse = 
  let eligibilityStatus = genEligibilityStatus(proofValid)
  result.requestId = requestId
  result.eligibilityStatus = eligibilityStatus

