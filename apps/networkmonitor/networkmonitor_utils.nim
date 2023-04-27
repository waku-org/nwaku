when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/json,
  stew/results,
  stew/shims/net,
  chronicles,
  chronicles/topics_registry,
  chronos,
  presto/[client,common]

type
  NodeLocation* = object
    country*: string
    city*: string
    lat*: string
    long*: string
    isp*: string

proc flatten*[T](a: seq[seq[T]]): seq[T] =
  var aFlat = newSeq[T](0)
  for subseq in a:
    aFlat &= subseq
  return aFlat

proc decodeBytes*(t: typedesc[NodeLocation], value: openArray[byte],
                  contentType: Opt[ContentTypeData]): RestResult[NodeLocation] =
  var res: string
  if len(value) > 0:
    res = newString(len(value))
    copyMem(addr res[0], unsafeAddr value[0], len(value))
    try:
      let jsonContent = parseJson(res)
      if $jsonContent["status"].getStr() != "success":
        error "query failed", result=jsonContent
        return err("query failed")
      return ok(NodeLocation(
        country: jsonContent["country"].getStr(),
        city:    jsonContent["city"].getStr(),
        lat:     $jsonContent["lat"].getFloat(),
        long:    $jsonContent["lon"].getFloat(),
        isp:     jsonContent["isp"].getStr()
      ))
    except Exception:
      return err("failed to get the location: " & getCurrentExceptionMsg())

proc encodeString*(value: string): RestResult[string] =
  ok(value)

proc ipToLocation*(ip: string): RestResponse[NodeLocation] {.rest, endpoint: "json/{ip}", meth: MethodGet.}
