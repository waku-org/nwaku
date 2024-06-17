import
  std/options,
  testutils/unittests,
  chronos

import
  ../../../waku/incentivization/[
    rpc,common
  ]


suite "Waku Incentivization Eligibility Testing":

    asyncTest "check eligibility success":
      var byteSequence: seq[byte] = @[1, 2, 3, 4, 5, 6, 7, 8]
      let eligibilityProof = EligibilityProof(proofOfPayment: some(byteSequence))
      check:
          isEligible(eligibilityProof)

    asyncTest "check eligibility failure":
      var byteSequence: seq[byte] = @[0, 2, 3, 4, 5, 6, 7, 8]
      let eligibilityProof = EligibilityProof(proofOfPayment: some(byteSequence))
      check:
          not isEligible(eligibilityProof)
