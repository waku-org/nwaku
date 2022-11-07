when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}
  
import
  std/[json,httpclient],
  chronicles,
  chronicles/topics_registry,
  chronos,
  stew/results

type
  NodeLocation = object
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

# using an external api retrieves some data associated with the ip
# TODO: use a cache
# TODO: use nim-presto's HTTP asynchronous client
proc ipToLocation*(ip: string,
                   client: Httpclient):
                   Future[Result[NodeLocation, string]] {.async.} =
  # naive mechanism to avoid hitting the rate limit
  # IP-API endpoints are now limited to 45 HTTP requests per minute
  await sleepAsync(1400)
  try:
    let content = client.getContent("http://ip-api.com/json/" & ip)
    let jsonContent = parseJson(content)

    if $jsonContent["status"].getStr() != "success":
      error "query failed", result=jsonContent
      return err("query failed: " & $jsonContent)

    return ok(NodeLocation(
      country: jsonContent["country"].getStr(),
      city:    jsonContent["city"].getStr(),
      lat:     jsonContent["lat"].getStr(),
      long:    jsonContent["lon"].getStr(),
      isp:     jsonContent["isp"].getStr()
    ))
  except:
    error "failed to get the location for IP", ip=ip, error=getCurrentExceptionMsg()
    return err("failed to get the location for IP '" & ip & "':" & getCurrentExceptionMsg())