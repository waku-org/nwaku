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
  ../../../waku/incentivization/rpc

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

proc genEligibilityStatus*(isEligible: bool): EligibilityStatus = 
  if isEligible:
    EligibilityStatus(
      statusCode: uint32(200),
      statusDesc: some("OK"))
  else:
    EligibilityStatus(
      statusCode: uint32(402),
      statusDesc: some("Payment Required"))