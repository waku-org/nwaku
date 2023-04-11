when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  stew/shims/net,
  chronicles,
  json_rpc/rpcserver
import
  ../../waku/v2/node/message_cache,
  ../../waku/v2/waku_node,
  ../../waku/v2/node/jsonrpc/admin/handlers as admin_api,
  ../../waku/v2/node/jsonrpc/debug/handlers as debug_api,
  ../../waku/v2/node/jsonrpc/filter/handlers as filter_api,
  ../../waku/v2/node/jsonrpc/relay/handlers as relay_api,
  ../../waku/v2/node/jsonrpc/store/handlers as store_api,
  ./config

logScope:
  topics = "wakunode jsonrpc"

proc startRpcServer(node: WakuNode, address: ValidIpAddress, port: Port, conf: WakuNodeConf): Result[RpcHttpServer, string] =
  let ta = initTAddress(address, port)

  var server: RpcHttpServer
  try:
    server = newRpcHttpServer([ta])
  except CatchableError:
    return err("failed to init JSON-RPC server: " & getCurrentExceptionMsg())

  installDebugApiHandlers(node, server)

  # TODO: Move to setup protocols proc
  if conf.relay:
    let relayMessageCache = relay_api.MessageCache.init(capacity=30)
    installRelayApiHandlers(node, server, relayMessageCache)
    if conf.rpcPrivate:
      installRelayPrivateApiHandlers(node, server, relayMessageCache)

  # TODO: Move to setup protocols proc
  if conf.filternode != "":
    let filterMessageCache = filter_api.MessageCache.init(capacity=30)
    installFilterApiHandlers(node, server, filterMessageCache)

  installStoreApiHandlers(node, server)

  if conf.rpcAdmin:
    installAdminApiHandlers(node, server)

  server.start()
  info "RPC Server started", address=ta

  ok(server)

proc startRpcServer*(node: WakuNode, address: ValidIpAddress, port: uint16, portsShift: uint16, conf: WakuNodeConf): Result[RpcHttpServer, string] =
  return startRpcServer(node, address, Port(port + portsShift), conf)
