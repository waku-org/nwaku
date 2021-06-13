## libwaku
##
## Exposes a C API that can be used by other environment than C.

import
  std/[options, tables, strutils, sequtils],
  chronos, chronicles, metrics,
  metrics/chronos_httpserver,
  confutils, json_rpc/rpcserver,

  stew/shims/net as stewNet,
  eth/keys,
  libp2p/multiaddress,
  libp2p/crypto/crypto,

  ../waku/v2/node/wakunode2,
  ../waku/v2/node/config,
  ../waku/v2/node/storage/message/message_store,
  ../waku/v2/node/storage/peer/peer_storage,
  ../waku/v2/node/storage/message/waku_message_store,
  ../waku/v2/node/storage/peer/waku_peer_storage,
  ../waku/v2/node/jsonrpc/[admin_api,
                           debug_api,
                           filter_api,
                           private_api,
                           relay_api,
                           store_api],
  ../waku/v2/protocol/[waku_relay, waku_message, message_notifier],
  ../waku/common/utils/nat

# TODO Start a node
# TODO Mock info call
# TODO Write header file
# TODO Write example C code file
# TODO Wrap info call
# TODO Init a node

# proc info*(node: WakuNode): WakuInfo =
proc info(foo: cstring): cstring {.exportc, dynlib.} =
  echo "info about node"
  echo foo
  return foo

proc startRpc(node: WakuNode, rpcIp: ValidIpAddress, rpcPort: Port, conf: WakuNodeConf) =
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


proc startMetricsServer(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort

    startMetricsHttpServer($serverIp, serverPort)

    info "Metrics HTTP server started", serverIp, serverPort

proc startMetricsLog() =
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

# XXX Async seems tricky with C here
proc nwaku_start(): bool {.exportc, dynlib.} =
  echo "Start WakuNode"

  let
    conf = WakuNodeConf.load()

  # Storage setup
  var sqliteDatabase: SqliteDatabase

  if conf.dbPath != "":
    let dbRes = SqliteDatabase.init(conf.dbPath)
    if dbRes.isErr:
      warn "failed to init database", err = dbRes.error
      waku_node_errors.inc(labelValues = ["init_db_failure"])
    else:
      sqliteDatabase = dbRes.value

  var pStorage: WakuPeerStorage

  if conf.persistPeers and not sqliteDatabase.isNil:
    let res = WakuPeerStorage.new(sqliteDatabase)
    if res.isErr:
      warn "failed to init new WakuPeerStorage", err = res.error
      waku_node_errors.inc(labelValues = ["init_store_failure"])
    else:
      pStorage = res.value

  let
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    ## @TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
    ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
    ## config, the external port is the same as the bind port.
    extPort = if extIp.isSome() and extTcpPort.isNone(): some(Port(uint16(conf.tcpPort) + conf.portsShift))
              else: extTcpPort
    node = WakuNode.init(conf.nodekey,
                         conf.listenAddress, Port(uint16(conf.tcpPort) + conf.portsShift),
                         extIp, extPort,
                         pStorage)

  # XXX Not async, so not waitFor
  discard node.start()

  if conf.swap:
    mountSwap(node)

  # TODO Set swap peer, for now should be same as store peer

  # Store setup
  if (conf.storenode != "") or (conf.store):
    var store: WakuMessageStore

    if (not sqliteDatabase.isNil) and conf.persistMessages:
      let res = WakuMessageStore.init(sqliteDatabase)
      if res.isErr:
        warn "failed to init WakuMessageStore", err = res.error
        waku_node_errors.inc(labelValues = ["init_store_failure"])
      else:
        store = res.value

    mountStore(node, store, conf.persistMessages)

    if conf.storenode != "":
      setStorePeer(node, conf.storenode)


  # Relay setup
  mountRelay(node,
             conf.topics.split(" "),
             rlnRelayEnabled = conf.rlnRelay,
             relayMessages = conf.relay) # Indicates if node is capable to relay messages

  # Keepalive mounted on all nodes
  mountKeepalive(node)

  # Resume historical messages, this has to be called after the relay setup
  if conf.store and conf.persistMessages:
    waitFor node.resume()

  if conf.staticnodes.len > 0:
    waitFor connectToNodes(node, conf.staticnodes)

  # NOTE Must be mounted after relay
  if (conf.lightpushnode != "") or (conf.lightpush):
    mountLightPush(node)

    if conf.lightpushnode != "":
      setLightPushPeer(node, conf.lightpushnode)

  # Filter setup. NOTE Must be mounted after relay
  if (conf.filternode != "") or (conf.filter):
    mountFilter(node)

    if conf.filternode != "":
      setFilterPeer(node, conf.filternode)

  if conf.rpc:
    startRpc(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift), conf)

  if conf.metricsLogging:
    startMetricsLog()

  if conf.metricsServer:
    startMetricsServer(conf.metricsServerAddress,
      Port(conf.metricsServerPort + conf.portsShift))

  return true

proc echo() {.exportc.} =
 echo "echo"

# TODO Here at the moment, start the node
# Then do info call
# WIP
#proc main() {.async.} =
#  let
#    rng = crypto.newRng()
#    conf = WakuNodeConf.load()
#    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
#      Port(uint16(conf.tcpPort) + conf.portsShift),
#      Port(uint16(conf.udpPort) + conf.portsShift))
#    node = WakuNode.init(conf.nodeKey, conf.listenAddress,
#      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)
#
#  await node.start()
#
#main()

  # When main done stuff

# Setup graceful shutdown

# XXX No node reference here

# # Handle Ctrl-C SIGINT
# proc handleCtrlC() {.noconv.} =
#   when defined(windows):
#     # workaround for https://github.com/nim-lang/Nim/issues/4057
#     setupForeignThreadGc()
#   info "Shutting down after receiving SIGINT"
#   waitFor node.stop()
#   quit(QuitSuccess)

# setControlCHook(handleCtrlC)

# # Handle SIGTERM
# when defined(posix):
#   proc handleSigterm(signal: cint) {.noconv.} =
#     info "Shutting down after receiving SIGTERM"
#     waitFor node.stop()
#     quit(QuitSuccess)

#   c_signal(SIGTERM, handleSigterm)


echo "hello there"
var foo = nwaku_start()
runForever()
