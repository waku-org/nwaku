when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client],
  stew/byteutils

import
  ../serdes,
  ../responses,
  ./types

export types


logScope:
  topics = "waku node rest admin api"

proc decodeBytes*(t: typedesc[seq[WakuPeer]], data: openArray[byte],
                  contentType: Opt[ContentTypeData]): RestResult[seq[WakuPeer]] =
  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported response contentType value", contentType = contentType
    return err("Unsupported response contentType")

  let decoded = decodeFromJsonBytes(seq[WakuPeer], data).valueOr:
    return err("Invalid response from server, could not decode.")

  return ok(decoded)

proc decodeBytes*(t: typedesc[string], value: openArray[byte],
                  contentType: Opt[ContentTypeData]): RestResult[string] =
  if MediaType.init($contentType) != MIMETYPE_TEXT:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  var res: string
  if len(value) > 0:
    res = newString(len(value))
    copyMem(addr res[0], unsafeAddr value[0], len(value))
  return ok(res)

proc encodeBytes*(value: seq[string],
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc getPeers*():
    RestResponse[seq[WakuPeer]]
    {.rest, endpoint: "/admin/v1/peers", meth: HttpMethod.MethodGet.}

proc postPeers*(body: seq[string]):
      RestResponse[string]
      {.rest, endpoint: "/admin/v1/peers", meth: HttpMethod.MethodPost.}
