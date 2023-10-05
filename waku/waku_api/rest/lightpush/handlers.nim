when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/strformat,
  std/sequtils,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/route,
  presto/common

import
  ../../../waku_core,
  ../../waku/node/peer_manager,
  ../../../waku_node,
  ../../waku/waku_lightpush,
  ../serdes,
  ../responses,
  ./types

export types

logScope:
  topics = "waku node rest lightpush api"

const futTimeoutForPushRequestProcessing* = 5.seconds

#### Request handlers

const ROUTE_LIGHTPUSH* = "/lightpush/v1/message"

func decodeRequestBody[T](contentBody: Option[ContentBody]) : Result[T, RestApiResponse] =
  if contentBody.isNone():
    return err(RestApiResponse.badRequest("Missing content body"))

  let reqBodyContentType = MediaType.init($contentBody.get().contentType)
  if reqBodyContentType != MIMETYPE_JSON:
    return err(RestApiResponse.badRequest("Wrong Content-Type, expected application/json"))

  let reqBodyData = contentBody.get().data

  let requestResult = decodeFromJsonBytes(T, reqBodyData)
  if requestResult.isErr():
    return err(RestApiResponse.badRequest("Invalid content body, could not decode. " &
                                          $requestResult.error))

  return ok(requestResult.get())

proc installLightPushRequestHandler*(router: var RestRouter,
                                             node: WakuNode) =

  router.api(MethodPost, ROUTE_LIGHTPUSH) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Send a request to push a waku message
    debug "post", ROUTE_LIGHTPUSH, contentBody

    let decodedBody = decodeRequestBody[PushRequest](contentBody)

    if decodedBody.isErr():
      return decodedBody.error()

    let req: PushRequest = decodedBody.value()
    let msg = req.message.toWakuMessage()

    if msg.isErr():
      return RestApiResponse.badRequest("Invalid message: {msg.error}")

    let peerOpt = node.peerManager.selectPeer(WakuLightPushCodec)
    if peerOpt.isNone():
      return RestApiResponse.serviceUnavailable("No suitable remote lightpush peers")

    let subFut = node.lightpushPublish(req.pubsubTopic,
                                       msg.value(),
                                       peerOpt.get())

    if not await subFut.withTimeout(futTimeoutForPushRequestProcessing):
      error "Failed to request a message push due to timeout!"
      return RestApiResponse.serviceUnavailable("Push request timed out")

    if subFut.value().isErr():
      return RestApiResponse.serviceUnavailable(fmt("Failed to request a message push: {subFut.value().error}"))

    return RestApiResponse.ok()
