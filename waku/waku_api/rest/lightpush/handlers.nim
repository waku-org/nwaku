{.push raises: [].}

import
  std/strformat,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/route,
  presto/common

import
  waku/node/peer_manager,
  waku/waku_lightpush/common,
  ../../../waku_node,
  ../../handlers,
  ../serdes,
  ../responses,
  ../rest_serdes,
  ./types

export types

logScope:
  topics = "waku node rest lightpush api"

const FutTimeoutForPushRequestProcessing* = 5.seconds

const NoPeerNoDiscoError =
  RestApiResponse.serviceUnavailable("No suitable service peer & no discovery method")

const NoPeerNoneFoundError =
  RestApiResponse.serviceUnavailable("No suitable service peer & none discovered")

proc useSelfHostedLightPush(node: WakuNode): bool =
  return node.wakuLegacyLightPush != nil and node.wakuLegacyLightPushClient == nil

proc convertErrorKindToHttpStatus(statusCode: LightpushStatusCode): HttpCode =
  ## Lightpush status codes are matching HTTP status codes by design
  return HttpCode(statusCode.int32)

proc makeRestResponse(response: WakuLightPushResult): RestApiResponse =
  var httpStatus: HttpCode = Http200
  var apiResponse: PushResponse

  if response.isOk():
    apiResponse.relayPeerCount = some(response.get())
  else:
    httpStatus = convertErrorKindToHttpStatus(response.error().code)
    apiResponse.statusDesc = response.error().desc

  let restResp = RestApiResponse.jsonResponse(apiResponse, status = httpStatus).valueOr:
    error "An error ocurred while building the json respose: ", error = error
    return RestApiResponse.internalServerError(
      fmt("An error ocurred while building the json respose: {error}")
    )

  return restResp

#### Request handlers
const ROUTE_LIGHTPUSH = "/lightpush/v3/message"

proc installLightPushRequestHandler*(
    router: var RestRouter,
    node: WakuNode,
    discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
) =
  router.api(MethodPost, ROUTE_LIGHTPUSH) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Send a request to push a waku message
    debug "post", ROUTE_LIGHTPUSH, contentBody

    let req: PushRequest = decodeRequestBody[PushRequest](contentBody).valueOr:
      return RestApiResponse.badRequest("Invalid push request: " & $error)

    let msg = req.message.toWakuMessage().valueOr:
      return RestApiResponse.badRequest("Invalid message: " & $error)

    var toPeer = none(RemotePeerInfo)
    if useSelfHostedLightPush(node):
      discard
    else:
      let aPeer = node.peerManager.selectPeer(WakuLightPushCodec).valueOr:
        let handler = discHandler.valueOr:
          return NoPeerNoDiscoError

        let peerOp = (await handler()).valueOr:
          return RestApiResponse.internalServerError("No value in peerOp: " & $error)

        peerOp.valueOr:
          return NoPeerNoneFoundError
      toPeer = some(aPeer)

    let subFut = node.lightpushPublish(req.pubsubTopic, msg, toPeer)

    if not await subFut.withTimeout(FutTimeoutForPushRequestProcessing):
      error "Failed to request a message push due to timeout!"
      return RestApiResponse.serviceUnavailable("Push request timed out")

    return makeRestResponse(subFut.value())
