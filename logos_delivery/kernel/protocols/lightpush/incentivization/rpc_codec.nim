import
  logos_delivery/kernel/[base/protobuf, protocols/lightpush/incentivization/rpc],
  results
protobufCodec(EligibilityProof)
proc validateDecoded(status: EligibilityStatus): ProtobufResult[void] =
  if status.statusCode == 0:
    return err(ProtobufError.missingRequiredField("status_code"))
  ok()

protobufCodec(EligibilityStatus, validateDecoded)
