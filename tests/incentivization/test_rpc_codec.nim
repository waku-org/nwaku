import
  std/options,
  std/strscans,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import
  ../../../waku/incentivization/rpc,
  ../../../waku/incentivization/rpc_codec


suite "Waku Incentivization Eligibility Codec":

    asyncTest "encode eligibility proof":
      var byteSequence: seq[byte] = @[1, 2, 3]
      let epRpc = EligibilityProof(proof: some(byteSequence))
      let encoded = encode(epRpc)
      let decoded = EligibilityProof.decode(encoded.buffer).get()
      check:
          epRpc == decoded
    
    asyncTest "encode eligibility status":
      let esRpc = EligibilityStatus(
        statusCode: some(uint32(200)),
        statusDesc: some("OK")
      )
      let encoded = encode(esRpc)
      let decoded = EligibilityStatus.decode(encoded.buffer).get()
      check:
        esRpc == decoded
