{.push raises: [].}

import
  results,
  logos_delivery/kernel/common/protobuf,
  logos_delivery/kernel/[protocols/message],
  ./rpc

const DefaultMaxPushResponseSize* = DefaultSafetyBufferProtocolOverhead
  ## The largest lightpush response that a client reads.

proc validateDecoded(rpc: PushRPC): ProtobufResult[void] =
  if rpc.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  if rpc.request.isSome():
    return validateWakuMessageFields(rpc.request.get().message)
  ok()

protobufCodec(PushRPC, validateDecoded)
