{.push raises: [].}

import std/[strutils, net]
import ../../../envvar_serialization

export net, envvar_serialization

proc readValue*(
    r: var EnvvarReader, value: var IpAddress
) {.raises: [SerializationError].} =
  try:
    value = parseIpAddress(r.readValue(string))
  except ValueError, IOError:
    raise newException(
      SerializationError, "Invalid IP address: " & getCurrentExceptionMsg()
    )

proc readValue*(r: var EnvvarReader, value: var Port) {.raises: [SerializationError].} =
  try:
    value = parseUInt(r.readValue(string)).Port
  except ValueError, IOError:
    raise newException(SerializationError, "Invalid Port: " & getCurrentExceptionMsg())
