when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import net, tables
import presto
import
  ../../waku/common/utils/nat,
  ../../waku/waku_node,
  ../../waku/discovery/waku_discv5,
  ../../waku/factory/external_config,
  ../../waku/waku_api/message_cache,
  ../../waku/waku_api/handlers,
  ../../waku/waku_api/rest/server,
  ../../waku/waku_api/rest/debug/handlers as rest_debug_api,
  ../../waku/waku_api/rest/relay/handlers as rest_relay_api,
  ../../waku/waku_api/rest/filter/handlers as rest_filter_api,
  ../../waku/waku_api/rest/lightpush/handlers as rest_lightpush_api,
  ../../waku/waku_api/rest/store/handlers as rest_store_api,
  ../../waku/waku_api/rest/health/handlers as rest_health_api,
  ../../waku/waku_api/rest/admin/handlers as rest_admin_api,
  ../../waku/waku_core/topics

proc startRestServer*(
    node: WakuNode,
    wakuDiscv5: Option[WakuDiscoveryV5],
    address: IpAddress,
    port: Port,
    conf: WakuNodeConf,
): Result[WakuRestServerRef, string] =
  # Used to register api endpoints that are not currently installed as keys,
  # values are holding error messages to be returned to the client
  var notInstalledTab: Table[string, string] = initTable[string, string]()

  let requestErrorHandler: RestRequestErrorHandler = proc(
      error: RestRequestError, request: HttpRequestRef
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    try:
      case error
      of RestRequestError.Invalid:
        return await request.respond(Http400, "Invalid request", HttpTable.init())
      of RestRequestError.NotFound:
        let paths = request.rawPath.split("/")
        let rootPath =
          if len(paths) > 1:
            paths[1]
          else:
            ""
        notInstalledTab.withValue(rootPath, errMsg):
          return await request.respond(Http404, errMsg[], HttpTable.init())
        do:
          return await request.respond(
            Http400,
            "Bad request initiated. Invalid path or method used.",
            HttpTable.init(),
          )
      of RestRequestError.InvalidContentBody:
        return await request.respond(Http400, "Invalid content body", HttpTable.init())
      of RestRequestError.InvalidContentType:
        return await request.respond(Http400, "Invalid content type", HttpTable.init())
      of RestRequestError.Unexpected:
        return defaultResponse()
    except HttpWriteError:
      error "Failed to write response to client", error = getCurrentExceptionMsg()
      discard

    return defaultResponse()

  let allowedOrigin =
    if len(conf.restAllowOrigin) > 0:
      some(conf.restAllowOrigin.join(","))
    else:
      none(string)

  let server =
    ?newRestHttpServer(
      address,
      port,
      allowedOrigin = allowedOrigin,
      requestErrorHandler = requestErrorHandler,
    )

  ## Admin REST API
  if conf.restAdmin:
    installAdminApiHandlers(server.router, node)

  ## Debug REST API
  installDebugApiHandlers(server.router, node)

  ## Health REST API
  installHealthApiHandler(server.router, node)

  ## Relay REST API
  if conf.relay:
    let cache = MessageCache.init(int(conf.restRelayCacheCapacity))

    let handler = messageCacheHandler(cache)

    for pubsubTopic in conf.pubsubTopics:
      cache.pubsubSubscribe(pubsubTopic)
      node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(handler))

    for contentTopic in conf.contentTopics:
      cache.contentSubscribe(contentTopic)
      node.subscribe((kind: ContentSub, topic: contentTopic), some(handler))

    installRelayApiHandlers(server.router, node, cache)
  else:
    notInstalledTab["relay"] =
      "/relay endpoints are not available. Please check your configuration: --relay"

  ## Filter REST API
  if conf.filternode != "" and node.wakuFilterClient != nil:
    let filterCache = MessageCache.init()

    let filterDiscoHandler =
      if wakuDiscv5.isSome():
        some(defaultDiscoveryHandler(wakuDiscv5.get(), Filter))
      else:
        none(DiscoveryHandler)

    rest_filter_api.installFilterRestApiHandlers(
      server.router, node, filterCache, filterDiscoHandler
    )
  else:
    notInstalledTab["filter"] =
      "/filter endpoints are not available. Please check your configuration: --filternode"

  ## Store REST API
  let storeDiscoHandler =
    if wakuDiscv5.isSome():
      some(defaultDiscoveryHandler(wakuDiscv5.get(), Store))
    else:
      none(DiscoveryHandler)

  installStoreApiHandlers(server.router, node, storeDiscoHandler)

  ## Light push API
  if conf.lightpushnode != "" and node.wakuLightpushClient != nil:
    let lightDiscoHandler =
      if wakuDiscv5.isSome():
        some(defaultDiscoveryHandler(wakuDiscv5.get(), Lightpush))
      else:
        none(DiscoveryHandler)

    rest_lightpush_api.installLightPushRequestHandler(
      server.router, node, lightDiscoHandler
    )
  else:
    notInstalledTab["lightpush"] =
      "/lightpush endpoints are not available. Please check your configuration: --lightpushnode"

  server.start()
  info "Starting REST HTTP server", url = "http://" & $address & ":" & $port & "/"

  return ok(server)
