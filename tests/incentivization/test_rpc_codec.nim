import
  std/options,
  std/strscans,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import
  ../../../waku/incentivization/rpc,
  ../../../waku/incentivization/rpc_codec,
  ../../../waku/incentivization/common

suite "Waku Incentivization Eligibility Codec":

    asyncTest "encode eligibility proof":
      let eligibilityProof = genEligibilityProof(true)
      let encoded = encode(eligibilityProof)
      let decoded = EligibilityProof.decode(encoded.buffer).get()
      check:
          eligibilityProof == decoded
    
    asyncTest "encode eligibility status":
      let eligibilityStatus = genEligibilityStatus(true)
      let encoded = encode(eligibilityStatus)
      let decoded = EligibilityStatus.decode(encoded.buffer).get()
      check:
        eligibilityStatus == decoded

    asyncTest "encode dummy request":
      let dummyRequest = genDummyRequestWithEligibilityProof(true)
      let encoded = encode(dummyRequest)
      let decoded = DummyRequest.decode(encoded.buffer).get()
      check:
          dummyRequest == decoded

    asyncTest "encode dummy response":
      var dummyResponse = genDummyResponseWithEligibilityStatus(true)
      let encoded = encode(dummyResponse)
      let decoded = DummyResponse.decode(encoded.buffer).get()
      check:
          dummyResponse == decoded

    