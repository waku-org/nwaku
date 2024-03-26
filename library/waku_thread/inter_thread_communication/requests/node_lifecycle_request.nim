import std/options
import std/sequtils
import chronos, chronicles, stew/results, stew/shims/net
import
  ../../../../waku/common/enr/builder,
  ../../../../waku/waku_enr/capabilities,
  ../../../../waku/waku_enr/multiaddr,
  ../../../../waku/waku_enr/sharding,
  ../../../../waku/waku_core/message/message,
  ../../../../waku/waku_core/message/default_values,
  ../../../../waku/waku_core/topics/pubsub_topic,
  ../../../../waku/node/peer_manager/peer_manager,
  ../../../../waku/waku_core,
  ../../../../waku/factory/external_config,
  ../../../../waku/node/waku_node,
  ../../../../waku/node/config,
  ../../../../waku/waku_archive/driver/builder,
  ../../../../waku/waku_archive/driver,
  ../../../../waku/waku_archive/retention_policy/builder,
  ../../../../waku/waku_archive/retention_policy,
  ../../../../waku/waku_relay/protocol,
  ../../../../waku/waku_store,
  ../../../../waku/factory/builder,
  ../../../../waku/factory/node_factory,
  ../../../apps/wakunode2/networks_config,
  ../../../events/[json_message_event, json_base_event],
  ../../../alloc,
  ../../config

type NodeLifecycleMsgType* = enum
  CREATE_NODE
  START_NODE
  STOP_NODE

type NodeLifecycleRequest* = object
  operation: NodeLifecycleMsgType
  configJson: cstring ## Only used in 'CREATE_NODE' operation

proc createShared*(
    T: type NodeLifecycleRequest, op: NodeLifecycleMsgType, configJson: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc createNode(configJson: cstring): Future[Result[WakuNode, string]] {.async.} =
  var conf: WakuNodeConf
  var errorResp: string

  try:
    if not parseConfig(
      $configJson,
      conf,
      errorResp,
    ):
      return err(errorResp)
  except Exception:
    return err("exception calling parseConfig: " & getCurrentExceptionMsg())

  # TODO: figure out how to extract default values from the config pragma
  conf.clusterId = 0
  conf.nat = "any"
  conf.maxConnections = 50.uint16
  conf.maxMessageSize = default_values.DefaultMaxWakuMessageSizeStr

  let nodeRes = setupNode(conf).valueOr():
    error "Failed setting up node", error = error
    return err("Failed setting up node: " & $error)

  return ok(nodeRes)

proc process*(
    self: ptr NodeLifecycleRequest, node: ptr WakuNode
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_NODE:
    let newNodeRes = await createNode(self.configJson)
    if newNodeRes.isErr():
      return err(newNodeRes.error)

    node[] = newNodeRes.get()
  of START_NODE:
    await node[].start()
  of STOP_NODE:
    try:
      await node[].stop()
    except Exception:
      return err("exception stopping node: " & getCurrentExceptionMsg())

  return ok("")
