import
  std/options,
  testutils/unittests,
  chronos

import
  ../../../waku/incentivization/[rpc, common, txid_proof]


suite "Waku Incentivization Eligibility Testing":

    asyncTest "check eligibility success with a txid-based proof":
      let eligibilityProof = genTxIdEligibilityProof(true)
      let isValid = await txidEligiblityCriteriaMet(eligibilityProof)
      check:
        isValid

    asyncTest "check eligibility failure with a txid-based proof":
      let eligibilityProof = genTxIdEligibilityProof(false)
      let isValid = await txidEligiblityCriteriaMet(eligibilityProof)
      check:
        not isValid
