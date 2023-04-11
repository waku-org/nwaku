when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  stew/shims/net,
  chronicles,
  presto
import
  ../../waku/v2/waku_node,
  ../../waku/v2/node/rest/server,
  ../../waku/v2/node/rest/debug/handlers as debug_api,
  ../../waku/v2/node/rest/relay/handlers as relay_api,
  ../../waku/v2/node/rest/relay/topic_cache,
  ../../waku/v2/node/rest/store/handlers as store_api,
  ./config


logScope:
  topics = "wakunode rest"


proc startRestServer(node: WakuNode, address: ValidIpAddress, port: Port, conf: WakuNodeConf): RestServerResult[RestServerRef] =
  let server = ? newRestHttpServer(address, port)

  ## Debug REST API
  installDebugApiHandlers(server.router, node)

  ## Relay REST API
  if conf.relay:
    let relayCache = TopicCache.init(capacity=conf.restRelayCacheCapacity)
    installRelayApiHandlers(server.router, node, relayCache)

  ## Store REST API
  installStoreApiHandlers(server.router, node)

  server.start()
  info "Starting REST HTTP server", url = "http://" & $address & ":" & $port & "/"

  ok(server)

proc startRestServer*(node: WakuNode, address: ValidIpAddress, port: uint16, portsShift: uint16, conf: WakuNodeConf): RestServerResult[RestServerRef] =
  return startRestServer(node, address, Port(port + portsShift), conf)
