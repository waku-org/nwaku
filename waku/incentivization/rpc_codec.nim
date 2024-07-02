import
  std/options
import
  ../common/protobuf,
  ../waku_core,
  ./rpc

const DefaultMaxRpcSize* = -1

# Codec for EligibilityProof

proc encode*(epRpc: EligibilityProof): ProtoBuffer = 
  var pb = initProtoBuffer()
  if epRpc.proofOfPayment.isSome():
    let proofOfPayment = epRpc.proofOfPayment.get()
    pb.write3(1, proofOfPayment)
  else:
    # there is no proof
    discard
  pb

proc decode*(T: type EligibilityProof, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var epRpc = EligibilityProof()
  var proofOfPayment = newSeq[byte]()
  if not ?pb.getField(1, proofOfPayment):
    epRpc.proofOfPayment = none(seq[byte])
  else:
    epRpc.proofOfPayment = some(proofOfPayment)
  ok(epRpc)

# Codec for EligibilityStatus

proc encode*(esRpc: EligibilityStatus): ProtoBuffer = 
  var pb = initProtoBuffer()
  pb.write3(1, esRpc.statusCode)
  if esRpc.statusDesc.isSome():
    pb.write3(2, esRpc.statusDesc.get())
  pb

proc decode*(T: type EligibilityStatus, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var esRpc = EligibilityStatus()
  # status code
  var code = uint32(0)
  if not ?pb.getField(1, code):
    # status code is mandatory
    return err(ProtobufError.missingRequiredField("status_code"))
  else:
    esRpc.statusCode = code
  # status description
  var description = ""
  if not ?pb.getField(2, description):
    esRpc.statusDesc = none(string)
  else:
    esRpc.statusDesc = some(description)
  ok(esRpc)
  

# Codec for DummyRequest

proc encode*(request: DummyRequest): ProtoBuffer = 
  var pb = initProtoBuffer()
  pb.write3(1, request.requestId)
  pb.write3(10, request.eligibilityProof.encode())
  pb

proc decode*(T: type DummyRequest, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var request = DummyRequest()

  if not ?pb.getField(1,request.requestId):
    return err(ProtobufError.missingRequiredField("requestId"))

  var eligibilityProofBytes: seq[byte]
  if not ?pb.getField(10, eligibilityProofBytes):
    return err(ProtobufError.missingRequiredField("eligibilityProof"))
  else:
    request.eligibilityProof = ?EligibilityProof.decode(eligibilityProofBytes)
  ok(request)


# Codec for DummyResponse

proc encode*(response: DummyResponse): ProtoBuffer = 
  var pb = initProtoBuffer()
  pb.write3(1, response.requestId)
  pb.write3(5, response.eligibilityStatus.encode())
  pb

proc decode*(T: type DummyResponse, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var response = DummyResponse()

  if not ?pb.getField(1,response.requestId):
    return err(ProtobufError.missingRequiredField("requestId"))

  var eligibilityStatusBytes: seq[byte]
  if not ?pb.getField(5, eligibilityStatusBytes):
    return err(ProtobufError.missingRequiredField("eligibilityStatus"))
  else:
    response.eligibilityStatus = ?EligibilityStatus.decode(eligibilityStatusBytes)
  ok(response)
