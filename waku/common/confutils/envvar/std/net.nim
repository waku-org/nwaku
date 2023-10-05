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
  except ValueError, IOError:
    raise newException(SerializationError, "Invalid IP address: " & getCurrentExceptionMsg())

proc readValue*(r: var EnvvarReader, value: var Port) {.raises: [SerializationError].} =
  try: 
    value = parseUInt(r.readValue(string)).Port
  except ValueError, IOError:
    raise newException(SerializationError, "Invalid Port: " & getCurrentExceptionMsg())
