import std/[options, json, strutils, net]
import chronos, chronicles, results, confutils, confutils/std/net

import
  ../../../../waku/node/peer_manager/peer_manager,
  ../../../../waku/factory/external_config,
  ../../../../waku/factory/waku,
  ../../../../waku/factory/node_factory,
  ../../../../waku/factory/networks_config,
  ../../../../waku/factory/waku_callbacks,
  ../../../alloc

type NodeLifecycleMsgType* = enum
  CREATE_NODE
  START_NODE
  STOP_NODE

type NodeLifecycleRequest* = object
  operation: NodeLifecycleMsgType
  configJson: cstring ## Only used in 'CREATE_NODE' operation
  callbacks: WakuCallbacks

proc createShared*(
    T: type NodeLifecycleRequest,
    op: NodeLifecycleMsgType,
    configJson: cstring = "",
    callbacks: WakuCallbacks = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].callbacks = callbacks
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc createWaku(
    configJson: cstring, callbacks: WakuCallbacks = nil
): Future[Result[Waku, string]] {.async.} =
  var conf = defaultWakuNodeConf().valueOr:
    return err("Failed creating node: " & error)

  var errorResp: string

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson($configJson)
  except Exception:
    return err(
      "exception in createWaku when calling parseJson: " & getCurrentExceptionMsg() &
        " configJson string: " & $configJson
    )

  for confField, confValue in fieldPairs(conf):
    if jsonNode.contains(confField):
      # Make sure string doesn't contain the leading or trailing " character
      let formattedString = ($jsonNode[confField]).strip(chars = {'\"'})
      # Override conf field with the value set in the json-string
      try:
        confValue = parseCmdArg(typeof(confValue), formattedString)
      except Exception:
        return err(
          "exception in createWaku when parsing configuration. exc: " &
            getCurrentExceptionMsg() & ". string that could not be parsed: " &
            formattedString & ". expected type: " & $typeof(confValue)
        )

  let wakuRes = Waku.new(conf, callbacks).valueOr:
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
    waku[] = (await createWaku(self.configJson, self.callbacks)).valueOr:
      error "CREATE_NODE failed", error = error
      return err("error processing createWaku request: " & $error)
  of START_NODE:
    (await waku.startWaku()).isOkOr:
      error "START_NODE failed", error = error
      return err("problem starting waku: " & $error)
  of STOP_NODE:
    try:
      await waku[].stop()
    except Exception:
      error "STOP_NODE failed", error = getCurrentExceptionMsg()
      return err("exception stopping node: " & getCurrentExceptionMsg())

  return ok("")
