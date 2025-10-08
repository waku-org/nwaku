import std/[options, json, strutils, net]
import chronos, chronicles, results, confutils, confutils/std/net, ffi

import
  ../../waku/node/peer_manager/peer_manager,
  ../../../tools/confutils/cli_args,
  ../../waku/factory/waku,
  ../../waku/factory/node_factory,
  ../../waku/factory/networks_config,
  ../../waku/factory/app_callbacks,
  ../../waku/waku_api/rest/builder

proc createWaku(
    configJson: cstring, appCallbacks: AppCallbacks = nil
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

  # Don't send relay app callbacks if relay is disabled
  if not conf.relay and not appCallbacks.isNil():
    appCallbacks.relayHandler = nil
    appCallbacks.topicHealthChangeHandler = nil

  # TODO: Convert `confJson` directly to `WakuConf`
  var wakuConf = conf.toWakuConf().valueOr:
    return err("Configuration error: " & $error)

  wakuConf.restServerConf = none(RestServerConf) ## don't want REST in libwaku

  let wakuRes = (await Waku.new(wakuConf, appCallbacks)).valueOr:
    error "waku initialization failed", error = error
    return err("Failed setting up Waku: " & $error)

  return ok(wakuRes)

registerReqFFI(CreateNodeRequest, waku: ptr Waku):
  proc(
      configJson: cstring, appCallbacks: AppCallbacks
  ): Future[Result[string, string]] {.async.} =
    waku[] = (await createWaku(configJson, cast[AppCallbacks](appCallbacks))).valueOr:
      error "CreateNodeRequest failed", error = error
      return err($error)
    return ok("")

registerReqFFI(StartNodeReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    (await waku.startWaku()).isOkOr:
      error "START_NODE failed", error = error
      return err("failed to start: " & $error)
    return ok("")

registerReqFFI(StopNodeReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    try:
      await waku[].stop()
    except Exception as exc:
      error "STOP_NODE failed", error = exc.msg
      return err("failed to stop: " & exc.msg)
    return ok("")
