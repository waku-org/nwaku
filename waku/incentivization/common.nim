import
  std/options,
  std/strscans,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import stew/results, chronos, libp2p/peerid

import
  ../../../waku/incentivization/rpc,
  ../../../waku/incentivization/rpc_codec

const DummyCodec* = "/vac/waku/dummy/0.0.1"

type DummyResult*[T] = Result[T, string]

type DummyHandler* = proc(
  peer: PeerId,
  dummyRequest: DummyRequest
): Future[DummyResult[void]] {.async.}

type
  DummyProtocolErrorKind* {.pure.} = enum
    UNKNOWN = uint32(000)
    BAD_RESPONSE = uint32(300)
    BAD_REQUEST = uint32(400)
    PAYMENT_REQUIRED = uint(402)  # error type specific for incentivization
    NOT_FOUND = uint32(404)
    SERVICE_UNAVAILABLE = uint32(503)
    PEER_DIAL_FAILURE = uint32(504)

  DummyProtocolError* = object
    case kind*: DummyProtocolErrorKind
    of PEER_DIAL_FAILURE:
      address*: string
    of BAD_RESPONSE, BAD_REQUEST, NOT_FOUND, SERVICE_UNAVAILABLE, PAYMENT_REQUIRED:
      cause*: string
    else:
      discard

  DummyProtocolResult* = Result[void, DummyProtocolError]


proc genEligibilityProof*(startsWithOne: bool): EligibilityProof = 
  let byteSequence: seq[byte] = (
    if startsWithOne:
      @[1, 2, 3, 4, 5, 6, 7, 8]
    else:
      @[0, 2, 3, 4, 5, 6, 7, 8])
  EligibilityProof(proofOfPayment: some(byteSequence))

proc genEligibilityStatus*(isEligible: bool): EligibilityStatus = 
  if isEligible:
    EligibilityStatus(
      statusCode: uint32(200),
      statusDesc: some("OK"))
  else:
    EligibilityStatus(
      statusCode: uint32(402),
      statusDesc: some("Payment Required"))

proc genDummyRequestWithEligibilityProof*(proofValid: bool, requestId: string = ""): DummyRequest =
  let eligibilityProof = genEligibilityProof(proofValid)
  result.requestId = requestId
  result.eligibilityProof = eligibilityProof

proc genDummyResponseWithEligibilityStatus*(proofValid: bool, requestId: string = ""): DummyResponse = 
  let eligibilityStatus = genEligibilityStatus(proofValid)
  result.requestId = requestId
  result.eligibilityStatus = eligibilityStatus

proc dummyEligibilityCriteriaMet(eligibilityProof: EligibilityProof): bool = 
  # a dummy criterion: the first element of the proof byte array equals 1
  let proofOfPayment = eligibilityProof.proofOfPayment
  if proofOfPayment.isSome:
    return (proofOfPayment.get()[0] == 1)
  else:
    return false

proc isEligible*(eligibilityProof: EligibilityProof): bool =
  dummyEligibilityCriteriaMet(eligibilityProof)
