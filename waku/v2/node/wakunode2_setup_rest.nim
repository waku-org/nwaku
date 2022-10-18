{.push raises: [Defect].}

import
  stew/shims/net,
  chronicles,
  presto
import
  ./config,
  ./waku_node,
  ./rest/server,
  ./rest/debug/debug_api,
  ./rest/relay/[relay_api, topic_cache]


logScope:
  topics = "wakunode.setup.rest"


proc startRestServer*(node: WakuNode, address: ValidIpAddress, port: Port, conf: WakuNodeConf) = 
  let serverResult = newRestHttpServer(address, port)
  if serverResult.isErr():
    notice "REST HTTP server could not be started", address = $address&":" & $port, reason = serverResult.error()
    return
  
  let server = serverResult.get()
  
  ## Debug REST API
  installDebugApiHandlers(server.router, node)

  ## Relay REST API
  if conf.relay:
    let relayCache = TopicCache.init(capacity=conf.restRelayCacheCapacity)
    installRelayApiHandlers(server.router, node, relayCache)

  server.start()
  info "Starting REST HTTP server", url = "http://" & $address & ":" & $port & "/"
