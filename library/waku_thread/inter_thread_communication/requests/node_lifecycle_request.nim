
import
  std/options
import
  chronos,
  chronicles,
  stew/results,
  stew/shims/net
import
  ../../../../waku/common/enr/builder,
  ../../../../waku/waku_enr/capabilities,
  ../../../../waku/waku_enr/multiaddr,
  ../../../../waku/waku_enr/sharding,
  ../../../../waku/waku_core/message/message,
  ../../../../waku/waku_core/topics/pubsub_topic,
  ../../../../waku/node/peer_manager/peer_manager,
  ../../../../waku/waku_core,
  ../../../../waku/node/waku_node,
  ../../../../waku/node/builder,
  ../../../../waku/node/config,
  ../../../../waku/waku_archive/driver/builder,
  ../../../../waku/waku_archive/driver,
  ../../../../waku/waku_archive/retention_policy/builder,
  ../../../../waku/waku_archive/retention_policy,
  ../../../../waku/waku_relay/protocol,
  ../../../../waku/waku_store,
  ../../../events/[json_error_event,json_message_event,json_base_event],
  ../../../alloc,
  ../../config

type
  NodeLifecycleMsgType* = enum
    CREATE_NODE
    START_NODE
    STOP_NODE

type
  NodeLifecycleRequest* = object
    operation: NodeLifecycleMsgType
    configJson: cstring ## Only used in 'CREATE_NODE' operation

proc createShared*(T: type NodeLifecycleRequest,
                   op: NodeLifecycleMsgType,
                   configJson: cstring = ""): ptr type T =

  var ret = createShared(T)
  ret[].operation = op
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc configureStore(node: WakuNode,
                    storeNode: string,
                    storeRetentionPolicy: string,
                    storeDbUrl: string,
                    storeVacuum: bool,
                    storeDbMigration: bool,
                    storeMaxNumDbConnections: int):
                    Future[Result[void, string]] {.async.} =
  ## This snippet is extracted/duplicated from the app.nim file

  var onErrAction = proc(msg: string) {.gcsafe, closure.} =
    ## Action to be taken when an internal error occurs during the node run.
    ## e.g. the connection with the database is lost and not recovered.
    # error "Unrecoverable error occurred", error = msg
    ## TODO: use a callback given as a parameter
    discard

  # Archive setup
  let archiveDriverRes = ArchiveDriver.new(storeDbUrl,
                                           storeVacuum,
                                           storeDbMigration,
                                           storeMaxNumDbConnections,
                                           onErrAction)
  if archiveDriverRes.isErr():
    return err("failed to setup archive driver: " & archiveDriverRes.error)

  let retPolicyRes = RetentionPolicy.new(storeRetentionPolicy)
  if retPolicyRes.isErr():
    return err("failed to create retention policy: " & retPolicyRes.error)

  let mountArcRes = node.mountArchive(archiveDriverRes.get(),
                                      retPolicyRes.get())
  if mountArcRes.isErr():
    return err("failed to mount waku archive protocol: " & mountArcRes.error)

  # Store setup
  try:
    await mountStore(node)
  except CatchableError:
    return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

  mountStoreClient(node)
  if storeNode != "":
    let storeNodeInfo = parsePeerInfo(storeNode)
    if storeNodeInfo.isOk():
      node.peerManager.addServicePeer(storeNodeInfo.value, WakuStoreCodec)
    else:
      return err("failed to set node waku store peer: " & storeNodeInfo.error)

  return ok()

proc createNode(configJson: cstring):
                Future[Result[WakuNode, string]] {.async.} =

  var privateKey: PrivateKey
  var netConfig = NetConfig.init(ValidIpAddress.init("127.0.0.1"),
                                 Port(60000'u16)).value

  ## relay
  var relay: bool
  var topics = @[""]

  ## store
  var store: bool
  var storeNode: string
  var storeRetentionPolicy: string
  var storeDbUrl: string
  var storeVacuum: bool
  var storeDbMigration: bool
  var storeMaxNumDbConnections: int

  var jsonResp: JsonEvent

  if not parseConfig($configJson,
                     privateKey,
                     netConfig,
                     relay,
                     topics,
                     store,
                     storeNode,
                     storeRetentionPolicy,
                     storeDbUrl,
                     storeVacuum,
                     storeDbMigration,
                     storeMaxNumDbConnections,
                     jsonResp):
    return err($jsonResp)

  var enrBuilder = EnrBuilder.init(privateKey)

  enrBuilder.withIpAddressAndPorts(
    netConfig.enrIp,
    netConfig.enrPort,
    netConfig.discv5UdpPort
  )

  if netConfig.wakuFlags.isSome():
    enrBuilder.withWakuCapabilities(netConfig.wakuFlags.get())

  enrBuilder.withMultiaddrs(netConfig.enrMultiaddrs)

  let addShardedTopics = enrBuilder.withShardedTopics(topics)
  if addShardedTopics.isErr():
    let msg = "Error setting shared topics: " & $addShardedTopics.error
    return err($JsonErrorEvent.new(msg))

  let recordRes = enrBuilder.build()
  let record =
    if recordRes.isErr():
      let msg = "Error building enr record: " & $recordRes.error
      return err($JsonErrorEvent.new(msg))

    else: recordRes.get()

  ## TODO: make the next const configurable from 'configJson'.
  const MAX_CONNECTIONS = 50.int

  var builder = WakuNodeBuilder.init()
  builder.withRng(crypto.newRng())
  builder.withNodeKey(privateKey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig)
  builder.withSwitchConfiguration(
    maxConnections = some(MAX_CONNECTIONS)
  )

  let wakuNodeRes = builder.build()
  if wakuNodeRes.isErr():
    let errorMsg = "failed to create waku node instance: " & wakuNodeRes.error
    return err($JsonErrorEvent.new(errorMsg))

  var newNode = wakuNodeRes.get()

  if relay:
    await newNode.mountRelay()
    newNode.peerManager.start()

  if store:
    (await newNode.configureStore(storeNode,
                                  storeRetentionPolicy,
                                  storeDbUrl,
                                  storeVacuum,
                                  storeDbMigration,
                                  storeMaxNumDbConnections)).isOkOr:
      return err("error configuring store: " & $error)

  return ok(newNode)

proc process*(self: ptr NodeLifecycleRequest,
              node: ptr WakuNode): Future[Result[string, string]] {.async.} =

  defer: destroyShared(self)

  case self.operation:
    of CREATE_NODE:
      let newNodeRes = await createNode(self.configJson)
      if newNodeRes.isErr():
        return err(newNodeRes.error)

      node[] = newNodeRes.get()

    of START_NODE:
      await node[].start()

    of STOP_NODE:
      await node[].stop()

  return ok("")
