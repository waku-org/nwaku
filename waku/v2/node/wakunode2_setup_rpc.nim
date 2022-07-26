{.push raises: [Defect].}

import
  std/tables,
  stew/shims/net,
  chronicles,
  json_rpc/rpcserver
import
  ./config,
  ./wakunode2,
  ./jsonrpc/[admin_api,
             debug_api,
             filter_api,
             relay_api,
             store_api,
             private_api,
             debug_api]

logScope:
  topics = "wakunode.setup.rpc"


proc startRpcServer*(node: WakuNode, rpcIp: ValidIpAddress, rpcPort: Port, conf: WakuNodeConf)
  {.raises: [Defect, RpcBindError].} =

  let
    ta = initTAddress(rpcIp, rpcPort)
    rpcServer = newRpcHttpServer([ta])
  
  installDebugApiHandlers(node, rpcServer)

  if conf.relay:
    let topicCache = newTable[string, seq[WakuMessage]]()
    installRelayApiHandlers(node, rpcServer, topicCache)

    if conf.rpcPrivate:
      # Private API access allows WakuRelay functionality that 
      # is backwards compatible with Waku v1.
      installPrivateApiHandlers(node, rpcServer, node.rng, topicCache)
  
  if conf.filter:
    let messageCache = newTable[ContentTopic, seq[WakuMessage]]()
    installFilterApiHandlers(node, rpcServer, messageCache)
  
  if conf.store:
    installStoreApiHandlers(node, rpcServer)
  
  if conf.rpcAdmin:
    installAdminApiHandlers(node, rpcServer)
  
  rpcServer.start()
  info "RPC Server started", ta