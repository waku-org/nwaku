{.push raises: [Defect].}

import
  libp2p/protobuf/minprotobuf,
  libp2p/varint
import
  ../../utils/protobuf,
  ./rpc

proc encode*(rpc: PeerExchangeRequest): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, rpc.numPeers)
  output.finish3()

  return output

proc init*(T: type PeerExchangeRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var rpc = PeerExchangeRequest(numPeers: 0)

  var numPeers: uint64
  if ?pb.getField(1, numPeers):
    rpc.numPeers = numPeers

  return ok(rpc)

proc encode*(rpc: PeerExchangePeerInfo): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, rpc.enr)
  output.finish3()

  return output

proc init*(T: type PeerExchangePeerInfo, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var rpc = PeerExchangePeerInfo(enr: @[])

  var peerInfoBuffer: seq[byte]
  if ?pb.getField(1, peerInfoBuffer):
      rpc.enr = peerInfoBuffer

  return ok(rpc)

proc encode*(rpc: PeerExchangeResponse): ProtoBuffer =
  var output = initProtoBuffer()

  for pi in rpc.peerInfos:
    output.write3(1, pi.encode())
  output.finish3()

  return output

proc init*(T: type PeerExchangeResponse, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var rpc = PeerExchangeResponse(peerInfos: @[])

  var peerInfoBuffers: seq[seq[byte]]
  if ?pb.getRepeatedField(1, peerInfoBuffers):
    for pib in peerInfoBuffers:
      rpc.peerInfos.add(?PeerExchangePeerInfo.init(pib))

  return ok(rpc)

proc encode*(rpc: PeerExchangeRpc): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(1, rpc.request.encode())
  output.write3(2, rpc.response.encode())
  output.finish3()

  return output

proc init*(T: type PeerExchangeRpc, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var rpc = PeerExchangeRpc()

  var requestBuffer: seq[byte]
  discard ?pb.getField(1, requestBuffer)
  rpc.request = ?PeerExchangeRequest.init(requestBuffer)

  var responseBuffer: seq[byte]
  discard ?pb.getField(2, responseBuffer)
  rpc.response = ?PeerExchangeResponse.init(responseBuffer)

  return ok(rpc)

