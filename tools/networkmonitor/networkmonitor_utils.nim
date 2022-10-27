import
  std/[json,httpclient]
import
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
  result = @[]
  for subseq in a:
    result &= subseq

# using an external api retrieves some data associated with the ip
# TODO: use a cache
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
    error "failed to get location for IP", ip=ip, excep=getCurrentException().msg
    return err("could not get location for IP: " & ip)