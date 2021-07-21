{.push raises: [Defect].}

## Collection of utilities commonly used
## during the setup phase of a Waku v2 node

import
  std/tables,
  chronos,
  chronicles,
  json_rpc/rpcserver,
  metrics,
  metrics/chronos_httpserver,
  stew/results,
  stew/shims/net,
  ./storage/sqlite,
  ./storage/migration/migration_types,
  ./jsonrpc/[admin_api,
             debug_api,
             filter_api,
             relay_api,
             store_api,
             private_api,
             debug_api],
  ./config,
  ./wakunode2

logScope:
  topics = "wakunode.setup"

type
  SetupResult*[T] = Result[T, string]

##########################
# Setup helper functions #
##########################

proc startRpc*(node: WakuNode, rpcIp: ValidIpAddress, rpcPort: Port, conf: WakuNodeConf)
  {.raises: [Defect, RpcBindError, CatchableError].} =
  # @TODO: API handlers still raise CatchableError

  let
    ta = initTAddress(rpcIp, rpcPort)
    rpcServer = newRpcHttpServer([ta])
  installDebugApiHandlers(node, rpcServer)

  # Install enabled API handlers:
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

proc startMetricsServer*(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    
    try:
      startMetricsHttpServer($serverIp, serverPort)
    except Exception as e:
      raiseAssert("Exception while starting metrics HTTP server: " & e.msg)

    info "Metrics HTTP server started", serverIp, serverPort

proc startMetricsLog*() =
  # https://github.com/nim-lang/Nim/issues/17369
  var logMetrics: proc(udata: pointer) {.gcsafe, raises: [Defect].}
  logMetrics = proc(udata: pointer) =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.
      var
        totalMessages = 0.float64

      for key in waku_node_messages.metrics.keys():
        try:
          totalMessages = totalMessages + waku_node_messages.value(key)
        except KeyError:
          discard

    info "Node metrics", totalMessages
    discard setTimer(Moment.fromNow(2.seconds), logMetrics)
  discard setTimer(Moment.fromNow(2.seconds), logMetrics)
  
proc runMigrations*(sqliteDatabase: SqliteDatabase, conf: WakuNodeConf) =
  # Run migration scripts on persistent storage

  var migrationPath: string
  if conf.persistPeers and conf.persistMessages:
    migrationPath = migration_types.ALL_STORE_MIGRATION_PATH
  elif conf.persistPeers:
    migrationPath = migration_types.PEER_STORE_MIGRATION_PATH
  elif conf.persistMessages:
    migrationPath = migration_types.MESSAGE_STORE_MIGRATION_PATH

  # run migration 
  info "running migration ... "
  let migrationResult = sqliteDatabase.migrate(migrationPath)
  if migrationResult.isErr:
    warn "migration failed"
  else:
    info "migration is done"
