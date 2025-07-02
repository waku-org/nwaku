import std/[options, json, strutils, net]
import chronos, chronicles, results, confutils, confutils/std/net, json_serialization

import
  ../../../waku/node/peer_manager/peer_manager,
  ../../../waku/factory/external_config,
  ../../../waku/factory/waku,
  ../../../waku/factory/node_factory,
  ../../../waku/factory/networks_config,
  ../../../waku/factory/app_callbacks,
  ../../../waku/waku_api/rest/builder,
  ../../alloc

type NodeLifecycleMsgType* = enum
  CREATE_NODE
  START_NODE
  STOP_NODE

type NodeLifecycleRequest* = object
  operation: NodeLifecycleMsgType
  configJson: cstring ## Only used in 'CREATE_NODE' operation
  appCallbacks: AppCallbacks

proc createShared*(
    T: type NodeLifecycleRequest,
    op: NodeLifecycleMsgType,
    configJson: cstring = "",
    appCallbacks: AppCallbacks = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].appCallbacks = appCallbacks
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc createWaku(
    configJson: cstring, appCallbacks: AppCallbacks = nil
): Future[Result[Waku, string]] {.async.} =
  let decodedConf = Json.decode(configJson, WakuNodeConf)

  var errorResp: string

  # Don't send relay app callbacks if relay is disabled
  if not decodedConf.relay and not appCallbacks.isNil():
    appCallbacks.relayHandler = nil
    appCallbacks.topicHealthChangeHandler = nil

  # TODO: Convert `confJson` directly to `WakuConf`
  var wakuConf = decodedConf.toWakuConf().valueOr:
    return err("Configuration error: " & $error)

  wakuConf.restServerConf = none(RestServerConf) ## don't want REST in libwaku

  let wakuRes = Waku.new(wakuConf, appCallbacks).valueOr:
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
    waku[] = (await createWaku(self.configJson, self.appCallbacks)).valueOr:
      error "CREATE_NODE failed", error = error
      return err($error)
  of START_NODE:
    (await waku.startWaku()).isOkOr:
      error "START_NODE failed", error = error
      return err($error)
  of STOP_NODE:
    try:
      await waku[].stop()
    except Exception:
      error "STOP_NODE failed", error = getCurrentExceptionMsg()
      return err(getCurrentExceptionMsg())

  return ok("")
