import
  stew/byteutils,
  json,
  json_rpc/rpcserver


func invalidMsg*(name: string): string =
  "When marshalling from JSON, parameter \"" & name & "\" is not valid"


## JSON marshalling

# seq[byte]

proc `%`*(value: seq[byte]): JsonNode =
  if value.len > 0:
    %("0x" & value.toHex())
  else:
    newJArray()
