import std/[options, sequtils, json, strutils, net]
import chronos, chronicles, stew/results, confutils, confutils/std/net

import
  ../../../../waku/node/peer_manager/peer_manager,
  ../../../../waku/factory/external_config,
  ../../../../waku/factory/waku,
  ../../../../waku/factory/node_factory,
  ../../../../waku/factory/networks_config,
  ../../../alloc

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
  var conf = defaultWakuNodeConf().valueOr:
    return err("Failed creating node: " & error)

  var errorResp: string

  try:
    let jsonNode = parseJson($configJson)

    for confField, confValue in fieldPairs(conf):
      if jsonNode.contains(confField):
        # Make sure string doesn't contain the leading or trailing " character
        let formattedString = ($jsonNode[confField]).strip(chars = {'\"'})
        # Override conf field with the value set in the json-string
        confValue = parseCmdArg(typeof(confValue), formattedString)
  except Exception:
    return err("exception parsing configuration: " & getCurrentExceptionMsg())

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
