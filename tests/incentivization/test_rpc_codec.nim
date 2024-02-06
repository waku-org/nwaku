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

proc createRequestWithProof(): DummyRequest = 
  var ep: EligibilityProof
  ep.proofType = EligibilityProofType.TX_ID
  ep.proof = "0xffffffff"
  result.requestId = "request1"
  result.eligibilityProof = some(ep)

proc createResponse(): DummyResponse = 
  var es: EligibilityStatus
  es.statusCode = 200
  es.statusDesc = "OK"
  result.requestId = "request1"
  result.eligibilityStatus = some(es)

suite "Waku Incentivization Eligibility Codec":

    asyncTest "encode eligibility request with proof":
      let req = createRequestWithProof()
      let decoded = DummyRequest.decode(encode(req).buffer).get()
      check:
          req == decoded
        
    asyncTest "encode eligibility response":
      let resp = createResponse()
      let decoded = DummyResponse.decode(encode(resp).buffer).get()
      check:
        resp == decoded