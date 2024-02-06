import
  std/options
import
  ../common/protobuf,
  ../waku_core,
  ./rpc


proc encode*(rpc: DummyRequest): ProtoBuffer = 
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)

  if rpc.eligibilityProof.isSome:
    let ep = rpc.eligibilityProof.get()
    pb.write3(2, uint32(ord(ep.proofType)))
    pb.write3(3, ep.proof)
  else:
    pb.write3(2, uint32(ord(EligibilityProofType.NONE)))

  pb

proc decode*(T: type DummyRequest, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var rpc = DummyRequest()

  if not ?pb.getField(1, rpc.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  var eligibilityProofType: uint32
  var eligibilityProof: EligibilityProof
  if not ?pb.getField(2, eligibilityProofType):
    eligibilityProof.proofType = EligibilityProofType.NONE
  elif eligibilityProofType == uint32(EligibilityProofType.NONE):
    eligibilityProof.proofType = EligibilityProofType.NONE
  else:
    eligibilityProof.proofType = EligibilityProofType(eligibilityProofType)

  var proof: string
  if not ?pb.getField(3, proof):
    return err(ProtobufError.missingRequiredField("proof"))
  else:
    eligibilityProof.proof = proof
    rpc.eligibilityProof = some(eligibilityProof)

  ok(rpc)


proc encode*(rpc: DummyResponse): ProtoBuffer = 
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)

  if rpc.eligibilityStatus.isSome:
    let es = rpc.eligibilityStatus.get()
    pb.write3(2, es.statusCode)
    pb.write3(3, es.statusDesc)

  pb


proc decode*(T: type DummyResponse, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var rpc = DummyResponse()

  if not ?pb.getField(1, rpc.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  var code: uint32
  var desc: string
  var eligibilityStatus: EligibilityStatus
  if ?pb.getField(2, code):
    eligibilityStatus.statusCode = code
    if ?pb.getField(3, desc):
      eligibilityStatus.statusDesc = desc
    else:
      # assuming description is not optional
      return err(ProtobufError.missingRequiredField("status_desc"))
    rpc.eligibilityStatus = some(eligibilityStatus)

  ok(rpc)
