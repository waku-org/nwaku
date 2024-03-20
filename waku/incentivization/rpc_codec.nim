import
  std/options
import
  ../common/protobuf,
  ../waku_core,
  ./rpc


# Codec for EligibilityProof

proc encode*(epRpc: EligibilityProof): ProtoBuffer = 
  var pb = initProtoBuffer()
  if epRpc.proof.isSome:
    let proof = epRpc.proof.get()
    pb.write3(1, proof)
  else:
    # there is no proof
    discard
  pb

proc decode*(T: type EligibilityProof, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var epRpc = EligibilityProof()
  var proof = newSeq[byte]()
  if not ?pb.getField(1, proof):
    epRpc.proof = none(seq[byte])
  else:
    epRpc.proof = some(proof)
  ok(epRpc)


# Codec for EligibilityStatus

proc encode*(esRpc: EligibilityStatus): ProtoBuffer = 
  var pb = initProtoBuffer()
  if esRpc.statusCode.isSome:
    pb.write3(1, esRpc.statusCode.get())
  if esRpc.statusDesc.isSome:
    pb.write3(2, esRpc.statusDesc.get())
  pb

proc decode*(T: type EligibilityStatus, buffer: seq[byte]): ProtobufResult[T] = 
  let pb = initProtoBuffer(buffer)
  var esRpc = EligibilityStatus()
  # status code
  # TODO: write this more concisely: ternary operator, default values?
  # something like this, if hasField by field number existed:
  #esRpc.statusCode = pb.hasField(1) ? some(pb.getField(1)) : none(uint32)
  # the same applies to the EligibilityProof's decode
  var code = uint32(0)
  if not ?pb.getField(1, code):
    esRpc.statusCode = none(uint32)
  else:
    esRpc.statusCode = some(code)
  # status description
  var description = ""
  if not ?pb.getField(2, description):
    esRpc.statusDesc = none(string)
  else:
    esRpc.statusDesc = some(description)
  ok(esRpc)
  

