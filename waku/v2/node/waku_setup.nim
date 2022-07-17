{.push raises: [Defect].}

## Collection of utilities commonly used
## during the setup phase of a Waku v2 node

import
  std/tables,
  chronos,
  chronicles,
  metrics,
  metrics/chronos_httpserver,
  stew/results,
  stew/shims/net,
  ./storage/sqlite,
  ./storage/migration/migration_types,
  ./config,
  ./wakunode2

logScope:
  topics = "wakunode.setup"

type
  SetupResult*[T] = Result[T, string]

##########################
# Setup helper functions #
##########################

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
  info "running migration ...", migrationPath=migrationPath
  let migrationResult = sqliteDatabase.migrate(migrationPath)
  if migrationResult.isErr:
    warn "migration failed", error=migrationResult.error
  else:
    info "migration is done"
