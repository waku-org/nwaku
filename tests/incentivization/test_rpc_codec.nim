import
  std/options,
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  web3

import
  ../../../waku/incentivization/[
    rpc,
    rpc_codec,
    common,
    txid_proof,
    eligibility
  ]

let txHash = TxHash.fromHex(
  "0x0000000000000000000000000000000000000000000000000000000000000000"
  )
let txHashAsBytes = @(txHash.bytes())

suite "Waku Incentivization Eligibility Codec":

    asyncTest "encode eligibility proof":
      let txHash = TxHash.fromHex(
        "0x0000000000000000000000000000000000000000000000000000000000000000")
      let txHashAsBytes = @(txHash.bytes())
      let eligibilityProof = EligibilityProof(proofOfPayment: some(txHashAsBytes))
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
      let txHash = TxHash.fromHex(
        "0x0000000000000000000000000000000000000000000000000000000000000000")
      let txHashAsBytes = @(txHash.bytes())
      let dummyRequest = genDummyRequestWithTxIdEligibilityProof(txHashAsBytes)
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

    