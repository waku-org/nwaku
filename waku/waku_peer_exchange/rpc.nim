import std/options

type
  PeerExchangePeerInfo* = object
    enr*: seq[byte] # RLP encoded ENR: https://eips.ethereum.org/EIPS/eip-778

  PeerExchangeRequest* = object
    numPeers*: uint64

  PeerExchangeResponse* = object
    peerInfos*: seq[PeerExchangePeerInfo]

  PeerExchangeResponseStatusCode* {.pure.} = enum
    UNKNOWN = uint32(000)
    SUCCESS = uint32(200)
    BAD_REQUEST = uint32(400)
    TOO_MANY_REQUESTS = uint32(429)
    SERVICE_UNAVAILABLE = uint32(503)

  PeerExchangeResponseStatus* = object
    status*: PeerExchangeResponseStatusCode
    desc*: Option[string]

  PeerExchangeRpc* = object
    request*: Option[PeerExchangeRequest]
    response*: Option[PeerExchangeResponse]
    responseStatus*: Option[PeerExchangeResponseStatus]

proc makeRequest*(T: type PeerExchangeRpc, numPeers: uint64): T =
  return T(request: some(PeerExchangeRequest(numPeers: numpeers)))

proc makeResponse*(T: type PeerExchangeRpc, peerInfos: seq[PeerExchangePeerInfo]): T =
  return T(
    response: some(PeerExchangeResponse(peerInfos: peerInfos)),
    responseStatus:
      some(PeerExchangeResponseStatus(status: PeerExchangeResponseStatusCode.SUCCESS)),
  )

proc makeErrorResponse*(
    T: type PeerExchangeRpc,
    status: PeerExchangeResponseStatusCode,
    desc: Option[string] = none(string),
): T =
  return T(responseStatus: some(PeerExchangeResponseStatus(status: status, desc: desc)))
