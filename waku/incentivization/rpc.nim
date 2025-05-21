import  
  std/[options, strutils],
  stew/byteutils,  
  json_serialization,  
  json_serialization/std/options,  
  ../waku_api/rest/serdes

# Implementing the RFC:
# https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/73

type
  EligibilityProof* = object
    proofOfPayment*: Option[seq[byte]]

  EligibilityStatus* = object
    statusCode*: uint32
    statusDesc*: Option[string]

proc writeValue*(
    writer: var JsonWriter[RestJson], value: EligibilityProof
) {.raises: [IOError].} =
  if value.proofOfPayment.isSome():
    writer.writeValue("0x" & value.proofOfPayment.get().toHex())
  else:
    writer.writeValue("")
  
proc readValue*(  
    reader: var JsonReader[RestJson], value: var EligibilityProof
) {.raises: [SerializationError, IOError].} =
  let hexStr = reader.readValue(string)
  if hexStr.len > 0:
    let startIndex = if hexStr.len > 2 and hexStr[0..1] == "0x": 2 else: 0
    try:
      let bytes = hexToSeqByte(hexStr[startIndex..^1])
      value = EligibilityProof(proofOfPayment: some(bytes))
    except ValueError as e:
      # Either handle the error or re-raise it
      raise newException(SerializationError, "Invalid hex string: " & e.msg)
  else:
    value = EligibilityProof(proofOfPayment: none(seq[byte]))