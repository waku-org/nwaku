{.push raises: [].}

import std/options
import ../common/protobuf, ./rpc

proc encode*(rpc: PeerExchangeRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.numPeers)
  pb.finish3()

  pb

proc decode*(T: type PeerExchangeRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeRequest(numPeers: 0)

  var numPeers: uint64
  if ?pb.getField(1, numPeers):
    rpc.numPeers = numPeers

  ok(rpc)

proc encode*(rpc: PeerExchangePeerInfo): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.enr)
  pb.finish3()

  pb

proc decode*(T: type PeerExchangePeerInfo, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangePeerInfo(enr: @[])

  var peerInfoBuffer: seq[byte]
  if ?pb.getField(1, peerInfoBuffer):
    rpc.enr = peerInfoBuffer

  ok(rpc)

proc encode*(rpc: PeerExchangeResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  for pi in rpc.peerInfos:
    pb.write3(1, pi.encode())

  pb.finish3()

  pb

proc decode*(T: type PeerExchangeResponse, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeResponse(peerInfos: @[])

  var peerInfoBuffers: seq[seq[byte]]
  if ?pb.getRepeatedField(1, peerInfoBuffers):
    for pib in peerInfoBuffers:
      rpc.peerInfos.add(?PeerExchangePeerInfo.decode(pib))

  ok(rpc)

proc parse*(T: type PeerExchangeResponseStatusCode, status: uint32): T =
  case status
  of 200, 400, 429, 503:
    PeerExchangeResponseStatusCode(status)
  else:
    PeerExchangeResponseStatusCode.UNKNOWN

proc encode*(rpc: PeerExchangeResponseStatus): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.status.uint32)
  pb.write3(2, rpc.desc)

  pb.finish3()

  pb

proc decode*(T: type PeerExchangeResponseStatus, buffer: seq[byte]): ProtobufResult[T] =
  var pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeResponseStatus(status: PeerExchangeResponseStatusCode.UNKNOWN)

  var status: uint32
  if ?pb.getField(1, status):
    rpc.status = PeerExchangeResponseStatusCode.parse(status)
  else:
    return err(ProtobufError.missingRequiredField("status"))

  var desc: string
  if ?pb.getField(2, desc):
    rpc.desc = some(desc)
  else:
    rpc.desc = none(string)

  ok(rpc)

proc encode*(rpc: PeerExchangeRpc): ProtoBuffer =
  var pb = initProtoBuffer()

  if rpc.request.isSome():
    pb.write3(1, rpc.request.get().encode())
  if rpc.response.isSome():
    pb.write3(2, rpc.response.get().encode())
  if rpc.responseStatus.isSome():
    pb.write3(10, rpc.responseStatus.get().encode())

  pb.finish3()

  pb

proc decode*(T: type PeerExchangeRpc, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeRpc()

  var requestBuffer: seq[byte]
  let isRequest = ?pb.getField(1, requestBuffer)

  var responseBuffer: seq[byte]
  let isResponse = ?pb.getField(2, responseBuffer)

  if isRequest and isResponse:
    return err(ProtobufError.missingRequiredField("request and response are exclusive"))

  if not isRequest and not isResponse:
    return err(ProtobufError.missingRequiredField("request"))

  if isRequest:
    rpc.request = some(?PeerExchangeRequest.decode(requestBuffer))

  if isResponse:
    rpc.response = some(?PeerExchangeResponse.decode(responseBuffer))

  var status: seq[byte]
  if ?pb.getField(10, status):
    rpc.responseStatus = some(?PeerExchangeResponseStatus.decode(status))
  elif not isRequest:
    return err(ProtobufError.missingRequiredField("responseStatus"))

  ok(rpc)
