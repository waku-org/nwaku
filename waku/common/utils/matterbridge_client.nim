import
  std/[httpclient, json, uri, options]

const
  # Resource locators
  stream* = "/api/stream"
  messages* = "/api/messages"
  message* = "/api/message"
  health* = "/api/health"

type
  MatterbridgeClient* = ref object of RootObj
    hostClient*: HttpClient
    host*: Uri
    gateway*: string

proc new*(T: type MatterbridgeClient,
          hostUri: string,
          gateway = "gateway1"): MatterbridgeClient =
  let mbClient = MatterbridgeClient()

  mbClient.hostClient = newHttpClient()
  mbClient.hostClient.headers = newHttpHeaders({ "Content-Type": "application/json" })
  
  mbClient.host = parseUri(hostUri)
  mbClient.gateway = gateway

  return mbClient

proc getMessages*(mb: MatterbridgeClient): seq[JsonNode] =
  let response = mb.hostClient.get($(mb.host / messages))
  assert response.status == "200 OK"

  return parseJson(response.body()).getElems()

proc postMessage*(mb: MatterbridgeClient, msg: JsonNode) =
  let response = mb.hostClient.request($(mb.host / message),
                                         httpMethod = HttpPost,
                                         body = $msg)

  assert response.status == "200 OK"

  # @TODO: better error-handling here

proc postMessage*(mb: MatterbridgeClient, text: string, username: string) =
  let jsonNode = %* {"text": text,
                     "username": username,
                     "gateway": mb.gateway}

  mb.postMessage(jsonNode)

proc isHealthy*(mb: MatterbridgeClient): bool =
  let response = mb.hostClient.get($(mb.host / health))

  return response.status == "200 OK" and response.body == "OK"
