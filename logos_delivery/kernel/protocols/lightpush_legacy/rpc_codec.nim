{.push raises: [].}

import logos_delivery/kernel/[common/protobuf, common/message], results, ./rpc
const DefaultMaxPushResponseSize* = DefaultSafetyBufferProtocolOverhead
  ## The largest lightpush response that a client reads.

proc validateDecoded(rpc: PushRPC): ProtobufResult[void] =
  if rpc.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  if rpc.request.isSome():
    return validateWakuMessageFields(rpc.request.get().message)
  ok()

protobufCodec(PushRPC, validateDecoded)
