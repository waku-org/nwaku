
import
  std/options
import
  chronos,
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
  ../../../../waku/waku_relay/protocol,
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

proc createNode(configJson: cstring):
                Future[Result[WakuNode, string]] {.async.} =

  var privateKey: PrivateKey
  var netConfig = NetConfig.init(ValidIpAddress.init("127.0.0.1"),
                                 Port(60000'u16)).value
  var relay: bool
  var topics = @[""]
  var jsonResp: JsonEvent

  if not parseConfig($configJson,
                     privateKey,
                     netConfig,
                     relay,
                     topics,
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
