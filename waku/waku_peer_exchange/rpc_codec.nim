{.push raises: [].}

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

proc encode*(rpc: PeerExchangeRpc): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.request.encode())
  pb.write3(2, rpc.response.encode())
  pb.finish3()

  pb

proc decode*(T: type PeerExchangeRpc, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeRpc()

  var requestBuffer: seq[byte]
  if not ?pb.getField(1, requestBuffer):
    return err(ProtoError.RequiredFieldMissing)
  rpc.request = ?PeerExchangeRequest.decode(requestBuffer)

  var responseBuffer: seq[byte]
  discard ?pb.getField(2, responseBuffer)
  rpc.response = ?PeerExchangeResponse.decode(responseBuffer)

  ok(rpc)
