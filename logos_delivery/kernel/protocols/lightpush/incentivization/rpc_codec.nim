import
  logos_delivery/kernel/[common/protobuf, protocols/lightpush/incentivization/rpc],
  results
protobufCodec(EligibilityProof)
proc validateDecoded(status: EligibilityStatus): ProtobufResult[void] =
  if status.statusCode == 0:
    return err(ProtobufError.missingRequiredField("status_code"))
  ok()

protobufCodec(EligibilityStatus, validateDecoded)
