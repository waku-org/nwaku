import std/options
import std/sequtils
import std/json

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
  ../../../../waku/factory/waku,
  ../../../../waku/node/config,
  ../../../../waku/waku_archive/driver/builder,
  ../../../../waku/waku_archive/driver,
  ../../../../waku/waku_archive/retention_policy/builder,
  ../../../../waku/waku_archive/retention_policy,
  ../../../../waku/waku_relay/protocol,
  ../../../../waku/waku_store,
  ../../../../waku/factory/builder,
  ../../../../waku/factory/node_factory,
  ../../../../waku/factory/networks_config,
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

proc createWaku(configJson: cstring): Future[Result[Waku, string]] {.async.} =
  #[ var conf = WakuNodeConf.load().valueOr:
    return err("Failed creating node: " & error) ]#

  #echo $configJson
  echo "--------------------------------------------------"
  var conf = defaultWakuNodeConf().valueOr:
    return err("Failed creating node: " & error)

  var errorResp: string

  try:
    let jsonNode = parseJson($configJson)

    #[ let jsonConf = %conf
    echo conf ]#

    for key, value in pairs(jsonNode):
      echo "Key: ", key, typeof(key), " with value: ", value, typeof(value)

    for confField, confValue in fieldPairs(conf):
      if jsonNode.contains(confField):
        echo "setting " & $confField
        if $confField == "storeMaxNumDbConnections":
          #echo "storeMaxNumDbConnections: " & $confValue
          echo typeof(confValue)
        confValue = parseCmdArg(typeof(confValue), jsonNode[confField].getStr())
  except Exception:
    return err("exception calling parsing configuration: " & getCurrentExceptionMsg())

  echo conf

  # The Waku Network config (cluster-id=1)
  if conf.clusterId == 1:
    ## TODO: This section is duplicated in wakunode2.nim. We need to move this to a common module
    let twnClusterConf = ClusterConf.TheWakuNetworkConf()
    if len(conf.shards) != 0:
      conf.pubsubTopics = conf.shards.mapIt(twnClusterConf.pubsubTopics[it.uint16])
    else:
      conf.pubsubTopics = twnClusterConf.pubsubTopics

    # Override configuration
    conf.maxMessageSize = twnClusterConf.maxMessageSize
    conf.clusterId = twnClusterConf.clusterId
    conf.rlnRelay = twnClusterConf.rlnRelay
    conf.rlnRelayEthContractAddress = twnClusterConf.rlnRelayEthContractAddress
    conf.rlnRelayDynamic = twnClusterConf.rlnRelayDynamic
    conf.rlnRelayBandwidthThreshold = twnClusterConf.rlnRelayBandwidthThreshold
    conf.discv5Discovery = twnClusterConf.discv5Discovery
    conf.discv5BootstrapNodes =
      conf.discv5BootstrapNodes & twnClusterConf.discv5BootstrapNodes
    conf.rlnEpochSizeSec = twnClusterConf.rlnEpochSizeSec
    conf.rlnRelayUserMessageLimit = twnClusterConf.rlnRelayUserMessageLimit

  let wakuRes = Waku.init(conf).valueOr:
    error "waku initialization failed", error = error
    return err("Failed setting up Waku: " & $error)

  return ok(wakuRes)

proc process*(
    self: ptr NodeLifecycleRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_NODE:
    waku[] = (await createWaku(self.configJson)).valueOr:
      return err("error processing createWaku request: " & $error)
  of START_NODE:
    (await waku.startWaku()).isOkOr:
      return err("problem starting waku: " & $error)
  of STOP_NODE:
    try:
      await waku[].stop()
    except Exception:
      return err("exception stopping node: " & getCurrentExceptionMsg())

  return ok("")
