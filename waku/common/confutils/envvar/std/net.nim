when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/strutils,
  stew/shims/net
import
  ../../../envvar_serialization

export
  net, 
  envvar_serialization


proc readValue*(r: var EnvvarReader, value: var ValidIpAddress) {.raises: [SerializationError].} =
  try: 
    value = ValidIpAddress.init(r.readValue(string))
  except ValueError:
    raise newException(EnvvarError, "Invalid IP address")

proc readValue*(r: var EnvvarReader, value: var Port) {.raises: [SerializationError, ValueError].} =
  try: 
    value = parseUInt(r.readValue(string)).Port
  except ValueError:
    raise newException(EnvvarError, "Invalid Port")
